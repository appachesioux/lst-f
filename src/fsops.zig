//! Execucao ordenada do plano, area de sessao, rollback e relatorio.
//!
//! Nenhum arquivo e apagado durante a aplicacao: o que sai vai por `rename()`
//! para `.lst-f-<pid>/` no diretorio-base, no modelo de arquivo de swap do Vim.
//! A area existe enquanto a sessao existe -- depois disso a remocao e definitiva.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const plan = @import("plan.zig");

pub const manifest_name = "manifest";

pub const Removed = struct {
    id: u32,
    /// Caminho original, relativo ao diretorio-base.
    path: []const u8,
    /// Nome dentro da area: o proprio ID. Mata colisao de basename entre
    /// subdiretorios e dispensa qualquer escape.
    stored: []const u8,
};

/// O que efetivamente aconteceu no disco. Serve ao rollback e ao undo.
pub const Applied = struct {
    created_dirs: []const []const u8 = &.{},
    renames: []const plan.Rename = &.{},
    removed: []const Removed = &.{},
    area: ?[]const u8 = null,

    pub fn isEmpty(a: Applied) bool {
        return a.created_dirs.len == 0 and a.renames.len == 0 and a.removed.len == 0;
    }
};

pub const Outcome = struct {
    /// `null` quando tudo passou.
    failure: ?Failure = null,
    applied: Applied,
    /// Erros encontrados durante o rollback. Lista vazia com `failure`
    /// preenchido significa que o rollback conseguiu desfazer tudo.
    rollback_errors: []const []const u8 = &.{},

    pub const Failure = struct {
        phase: []const u8,
        detail: []const u8,
        err: anyerror,
    };
};

pub const AreaError = error{
    /// Sem permissao de escrita no diretorio-base: nao da para criar a area,
    /// logo nao da para garantir rollback da remocao.
    AreaUnavailable,
};

/// Area de sessao aberta em um diretorio-base.
pub const Area = struct {
    name: []const u8,
    dir: Io.Dir,
    manifest: Io.File,
    manifest_writer: *Io.File.Writer,

    pub fn close(a: *Area, io: Io) void {
        a.manifest_writer.interface.flush() catch {};
        a.manifest.close(io);
        a.dir.close(io);
    }
};

pub fn areaName(arena: Allocator, pid: std.posix.pid_t) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{d}", .{ plan.area_prefix, pid });
}

/// Cria a area sob demanda. Falha por permissao vira `AreaUnavailable`, que a
/// CLI traduz em recusa explicita da remocao.
pub fn openArea(arena: Allocator, io: Io, base: Io.Dir, name: []const u8) !Area {
    base.createDir(io, name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return error.AreaUnavailable,
        else => return err,
    };
    var dir = base.openDir(io, name, .{ .iterate = true }) catch return error.AreaUnavailable;
    errdefer dir.close(io);
    const file = dir.createFile(io, manifest_name, .{ .truncate = false }) catch return error.AreaUnavailable;
    const buffer = try arena.alloc(u8, 4096);
    const writer = try arena.create(Io.File.Writer);
    writer.* = .init(file, io, buffer);
    // Reabrir a area no meio da sessao nao pode sobrescrever o manifesto:
    // a escrita continua do fim do que ja esta la.
    if (file.stat(io)) |st| {
        writer.pos = st.size;
    } else |_| {}
    return .{ .name = name, .dir = dir, .manifest = file, .manifest_writer = writer };
}

/// Executa o plano. Uma fase por vez; em qualquer falha tenta o rollback em
/// ordem reversa e devolve o estado exato para o relatorio.
///
/// Nao promete atomicidade: POSIX nao tem transacao de filesystem e o proprio
/// rollback pode falhar. Promete validacao forte e estado sempre legivel.
pub fn apply(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    p: plan.Plan,
    area: ?*Area,
) Allocator.Error!Outcome {
    var created: std.ArrayList([]const u8) = .empty;
    var renamed: std.ArrayList(plan.Rename) = .empty;
    var removed: std.ArrayList(Removed) = .empty;

    var failure: ?Outcome.Failure = null;

    // Fase 1: diretorios pai.
    phase1: for (p.mkdirs) |dir_path| {
        switch (dirStatus(io, base, dir_path)) {
            .dir => continue,
            .symlink => {
                failure = .{
                    .phase = "criar diretorio",
                    .detail = dir_path,
                    .err = error.SymlinkInPath,
                };
                break :phase1;
            },
            .other => {
                failure = .{
                    .phase = "criar diretorio",
                    .detail = dir_path,
                    .err = error.PathAlreadyExists,
                };
                break :phase1;
            },
            .missing => {},
        }
        base.createDir(io, dir_path, .default_dir) catch |err| {
            failure = .{ .phase = "criar diretorio", .detail = dir_path, .err = err };
            break :phase1;
        };
        try created.append(arena, dir_path);
    }

    // Fase 2: renomeacoes e movimentos.
    if (failure == null) {
        for (p.renames) |r| {
            base.renamePreserve(r.from, base, r.to, io) catch |err| {
                failure = .{
                    .phase = "renomear",
                    .detail = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ r.from, r.to }),
                    .err = err,
                };
                break;
            };
            try renamed.append(arena, r);
        }
    }

    // Fase 3: remocoes, sempre por ultimo.
    if (failure == null and p.removes.len > 0) {
        const a = area.?;
        for (p.removes) |rm| {
            const stored = try std.fmt.allocPrint(arena, "{d:0>4}", .{rm.id});
            base.renamePreserve(rm.path, a.dir, stored, io) catch |err| {
                failure = .{ .phase = "remover", .detail = rm.path, .err = err };
                break;
            };
            const w = &a.manifest_writer.interface;
            w.print("{s}\x00{s}\x00", .{ stored, rm.path }) catch {};
            w.flush() catch {};
            try removed.append(arena, .{ .id = rm.id, .path = rm.path, .stored = stored });
        }
    }

    var applied: Applied = .{
        .created_dirs = try created.toOwnedSlice(arena),
        .renames = try renamed.toOwnedSlice(arena),
        .removed = try removed.toOwnedSlice(arena),
        .area = if (area) |a| a.name else null,
    };

    if (failure == null) return .{ .applied = applied, .failure = null };

    const errors = try revert(arena, io, base, applied, if (area) |a| a.dir else null);
    if (errors.len == 0) applied = .{};
    return .{ .failure = failure, .applied = applied, .rollback_errors = errors };
}

/// Desfaz `applied` em ordem reversa. Serve ao rollback de falha e ao undo da
/// sessao -- e o mesmo mecanismo, so muda quem chama.
pub fn revert(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    applied: Applied,
    area_dir: ?Io.Dir,
) Allocator.Error![]const []const u8 {
    var errors: std.ArrayList([]const u8) = .empty;

    if (area_dir) |a| {
        var i = applied.removed.len;
        while (i > 0) {
            i -= 1;
            const rm = applied.removed[i];
            a.renamePreserve(rm.stored, base, rm.path, io) catch |err| {
                try errors.append(arena, try std.fmt.allocPrint(
                    arena,
                    "restaurar {s} de {s}: {s}",
                    .{ rm.path, rm.stored, @errorName(err) },
                ));
            };
        }
    }

    var i = applied.renames.len;
    while (i > 0) {
        i -= 1;
        const r = applied.renames[i];
        base.renamePreserve(r.to, base, r.from, io) catch |err| {
            try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "desfazer {s} -> {s}: {s}",
                .{ r.from, r.to, @errorName(err) },
            ));
        };
    }

    var j = applied.created_dirs.len;
    while (j > 0) {
        j -= 1;
        base.deleteDir(io, applied.created_dirs[j]) catch |err| switch (err) {
            error.DirNotEmpty, error.FileNotFound => {},
            else => try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "remover diretorio criado {s}: {s}",
                .{ applied.created_dirs[j], @errorName(err) },
            )),
        };
    }

    return errors.toOwnedSlice(arena);
}

const DirStatus = enum { dir, symlink, other, missing };

fn dirStatus(io: Io, base: Io.Dir, path: []const u8) DirStatus {
    const st = base.statFile(io, path, .{ .follow_symlinks = false }) catch return .missing;
    return switch (st.kind) {
        .directory => .dir,
        .sym_link => .symlink,
        else => .other,
    };
}

/// Quantos itens existem na subarvore. E o numero que evita marcar um
/// diretorio inteiro sem perceber, entao aparece no diff.
pub fn subtreeCount(io: Io, base: Io.Dir, path: []const u8) u32 {
    var dir = base.openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch return 0;
    defer dir.close(io);
    return countDir(io, dir, 0);
}

fn countDir(io: Io, dir: Io.Dir, depth: u16) u32 {
    if (depth > 32) return 0;
    var total: u32 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        total += 1;
        if (e.kind != .directory) continue;
        var sub = dir.openDir(io, e.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
        defer sub.close(io);
        total += countDir(io, sub, depth + 1);
    }
    return total;
}

// ---------------------------------------------------------------------------
// Areas orfas
// ---------------------------------------------------------------------------

pub const Orphan = struct {
    name: []const u8,
    pid: std.posix.pid_t,
    items: u32,
};

/// Areas de sessoes que morreram (crash, kill, queda de SSH). Avisar e so
/// isso: nem restaurar, nem apagar sozinho, como o Vim faz com `.swp`.
pub fn scanOrphans(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    self_pid: std.posix.pid_t,
) Allocator.Error![]const Orphan {
    var out: std.ArrayList(Orphan) = .empty;
    var it = base.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        if (!std.mem.startsWith(u8, e.name, plan.area_prefix)) continue;
        const digits = e.name[plan.area_prefix.len..];
        const pid = std.fmt.parseInt(std.posix.pid_t, digits, 10) catch continue;
        if (pid == self_pid) continue;
        if (processAlive(pid)) continue;

        var dir = base.openDir(io, e.name, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var items: u32 = 0;
        var sub_it = dir.iterate();
        while (sub_it.next(io) catch null) |sub| {
            if (std.mem.eql(u8, sub.name, manifest_name)) continue;
            items += 1;
        }
        try out.append(arena, .{ .name = try arena.dupe(u8, e.name), .pid = pid, .items = items });
    }
    return out.toOwnedSlice(arena);
}

fn processAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    return true;
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

const Harness = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    io: Io,

    fn init(io: Io) Harness {
        return .{
            .tmp = testing.tmpDir(.{ .iterate = true }),
            .arena_state = .init(testing.allocator),
            .io = io,
        };
    }
    fn deinit(h: *Harness) void {
        h.arena_state.deinit();
        h.tmp.cleanup();
    }
    fn a(h: *Harness) Allocator {
        return h.arena_state.allocator();
    }
    fn dir(h: *Harness) Io.Dir {
        return h.tmp.dir;
    }
    fn touch(h: *Harness, path: []const u8, contents: []const u8) !void {
        try h.dir().writeFile(h.io, .{ .sub_path = path, .data = contents });
    }
    fn exists(h: *Harness, path: []const u8) bool {
        _ = h.dir().statFile(h.io, path, .{ .follow_symlinks = false }) catch return false;
        return true;
    }
    fn read(h: *Harness, path: []const u8) ![]u8 {
        return h.dir().readFileAlloc(h.io, path, h.a(), .limited(4096));
    }
};

fn planFor(
    arena: Allocator,
    originals: []const plan.Original,
    edits: []const plan.Edit,
) !plan.Plan {
    const res = try plan.build(arena, originals, edits, .{});
    return switch (res) {
        .ok => |p| p,
        .invalid => error.UnexpectedInvalidPlan,
    };
}

test "aplica renomeacao e troca ciclica no disco" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("a.txt", "conteudo A");
    try h.touch("b.txt", "conteudo B");

    const originals = [_]plan.Original{
        .{ .id = 1, .path = "a.txt", .kind = .file },
        .{ .id = 2, .path = "b.txt", .kind = .file },
    };
    const edits = [_]plan.Edit{
        .{ .id = 1, .path = "b.txt", .line = 1 },
        .{ .id = 2, .path = "a.txt", .line = 2 },
    };
    const p = try planFor(h.a(), &originals, &edits);
    const outcome = try apply(h.a(), io, h.dir(), p, null);
    try testing.expect(outcome.failure == null);

    try testing.expectEqualStrings("conteudo B", try h.read("a.txt"));
    try testing.expectEqualStrings("conteudo A", try h.read("b.txt"));
}

test "cria diretorio pai e desfaz no undo" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("doc.txt", "x");
    const originals = [_]plan.Original{.{ .id = 1, .path = "doc.txt", .kind = .file }};
    const edits = [_]plan.Edit{.{ .id = 1, .path = "docs/sub/doc.txt", .line = 1 }};
    const p = try planFor(h.a(), &originals, &edits);

    const outcome = try apply(h.a(), io, h.dir(), p, null);
    try testing.expect(outcome.failure == null);
    try testing.expect(h.exists("docs/sub/doc.txt"));

    const errors = try revert(h.a(), io, h.dir(), outcome.applied, null);
    try testing.expectEqual(@as(usize, 0), errors.len);
    try testing.expect(h.exists("doc.txt"));
    try testing.expect(!h.exists("docs"));
}

test "remocao vai para a area e volta no undo" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("some.txt", "adeus");
    const originals = [_]plan.Original{.{ .id = 7, .path = "some.txt", .kind = .file }};
    const p = try planFor(h.a(), &originals, &.{});

    const name = try areaName(h.a(), 4242);
    var area = try openArea(h.a(), io, h.dir(), name);
    defer area.close(io);

    const outcome = try apply(h.a(), io, h.dir(), p, &area);
    try testing.expect(outcome.failure == null);
    try testing.expect(!h.exists("some.txt"));
    try testing.expect(h.exists(".lst-f-4242/0007"));

    // O manifesto casa ID e caminho original, separado por NUL.
    const manifest = try h.read(".lst-f-4242/manifest");
    try testing.expectEqualStrings("0007\x00some.txt\x00", manifest);

    const errors = try revert(h.a(), io, h.dir(), outcome.applied, area.dir);
    try testing.expectEqual(@as(usize, 0), errors.len);
    try testing.expectEqualStrings("adeus", try h.read("some.txt"));
}

test "mesmo basename de subdiretorios diferentes nao colide na area" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.dir().createDirPath(io, "x");
    try h.dir().createDirPath(io, "y");
    try h.touch("x/nota.txt", "de x");
    try h.touch("y/nota.txt", "de y");

    const originals = [_]plan.Original{
        .{ .id = 1, .path = "x/nota.txt", .kind = .file },
        .{ .id = 2, .path = "y/nota.txt", .kind = .file },
    };
    const p = try planFor(h.a(), &originals, &.{});

    const name = try areaName(h.a(), 4243);
    var area = try openArea(h.a(), io, h.dir(), name);
    defer area.close(io);
    const outcome = try apply(h.a(), io, h.dir(), p, &area);
    try testing.expect(outcome.failure == null);
    try testing.expectEqualStrings("de x", try h.read(".lst-f-4243/0001"));
    try testing.expectEqualStrings("de y", try h.read(".lst-f-4243/0002"));
}

test "diretorio nao-vazio vai inteiro em um rename" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.dir().createDirPath(io, "dir/sub");
    try h.touch("dir/a", "1");
    try h.touch("dir/sub/b", "2");
    try testing.expectEqual(@as(u32, 3), subtreeCount(io, h.dir(), "dir"));

    const originals = [_]plan.Original{.{ .id = 3, .path = "dir", .kind = .dir }};
    const p = try planFor(h.a(), &originals, &.{});
    const name = try areaName(h.a(), 4244);
    var area = try openArea(h.a(), io, h.dir(), name);
    defer area.close(io);
    const outcome = try apply(h.a(), io, h.dir(), p, &area);
    try testing.expect(outcome.failure == null);
    try testing.expect(!h.exists("dir"));
    try testing.expectEqualStrings("2", try h.read(".lst-f-4244/0003/sub/b"));
}

test "falha no meio da fase de rename faz rollback completo" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("a", "A");
    try h.touch("b", "B");
    try h.touch("ocupado", "nao me sobrescreva");

    // O segundo rename colide com um arquivo que o plano nao conhece: e
    // exatamente o caso que `renamePreserve` (RENAME_NOREPLACE) protege.
    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{
            .{ .from = "a", .to = "a2" },
            .{ .from = "b", .to = "ocupado" },
        },
        .removes = &.{},
        .moves = &.{},
        .unchanged = 0,
    };
    const outcome = try apply(h.a(), io, h.dir(), p, null);
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(@as(usize, 0), outcome.rollback_errors.len);
    try testing.expect(outcome.applied.isEmpty());
    try testing.expect(h.exists("a"));
    try testing.expect(h.exists("b"));
    try testing.expectEqualStrings("nao me sobrescreva", try h.read("ocupado"));
}

test "falha na fase de remocao devolve os arquivos ja movidos" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("um", "1");
    try h.touch("dois", "2");

    const name = try areaName(h.a(), 4245);
    var area = try openArea(h.a(), io, h.dir(), name);
    defer area.close(io);
    // Planta uma colisao dentro da area para forcar a falha no segundo remove.
    try h.touch(".lst-f-4245/0002", "impostor");

    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{},
        .removes = &.{
            .{ .id = 1, .path = "um", .kind = .file },
            .{ .id = 2, .path = "dois", .kind = .file },
        },
        .moves = &.{},
        .unchanged = 0,
    };
    const outcome = try apply(h.a(), io, h.dir(), p, &area);
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(@as(usize, 0), outcome.rollback_errors.len);
    try testing.expectEqualStrings("1", try h.read("um"));
    try testing.expectEqualStrings("2", try h.read("dois"));
}

test "area orfa de PID morto e detectada" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    // PID improvavel de existir; se existir, o teste apenas nao encontra a orfa.
    try h.dir().createDirPath(io, ".lst-f-999999");
    try h.touch(".lst-f-999999/0001", "restos");
    try h.touch(".lst-f-999999/manifest", "0001\x00antigo.txt\x00");

    const orphans = try scanOrphans(h.a(), io, h.dir(), 1);
    if (processAlive(999999)) return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 1), orphans.len);
    try testing.expectEqualStrings(".lst-f-999999", orphans[0].name);
    try testing.expectEqual(@as(u32, 1), orphans[0].items);
}

test "symlink no caminho do pai bloqueia a criacao" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("f.txt", "x");
    try h.dir().symLink(io, "/tmp", "fora", .{});

    const p: plan.Plan = .{
        .mkdirs = &.{"fora"},
        .renames = &.{.{ .from = "f.txt", .to = "fora/f.txt" }},
        .removes = &.{},
        .moves = &.{},
        .unchanged = 0,
    };
    const outcome = try apply(h.a(), io, h.dir(), p, null);
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(error.SymlinkInPath, outcome.failure.?.err);
    try testing.expect(h.exists("f.txt"));
}
