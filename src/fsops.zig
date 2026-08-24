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
    /// Criacoes pedidas por linha sem ID. Saem antes de desfazer as
    /// renomeacoes: podem estar ocupando um nome que precisa voltar.
    created: []const plan.Create = &.{},
    renames: []const plan.Rename = &.{},
    /// Copias materializadas; o undo as remove.
    copied: []const plan.Copy = &.{},
    removed: []const Removed = &.{},
    /// Quantas remocoes (prefixo de `removed`) aconteceram antes das
    /// renomeacoes; o rollback as restaura depois de desfazer os renames.
    removed_before: usize = 0,
    area: ?[]const u8 = null,

    pub fn isEmpty(a: Applied) bool {
        return a.created_dirs.len == 0 and a.created.len == 0 and
            a.renames.len == 0 and a.copied.len == 0 and a.removed.len == 0;
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
    var new_entries: std.ArrayList(plan.Create) = .empty;
    var renamed: std.ArrayList(plan.Rename) = .empty;
    var removed: std.ArrayList(Removed) = .empty;
    var copied: std.ArrayList(plan.Copy) = .empty;

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

    // Fase 2: remocoes antecipadas, antes das renomeacoes -- o destino delas
    // precisa estar livre na hora do rename.
    if (failure == null and p.removes_before > 0) {
        const a = area.?;
        for (p.removes[0..p.removes_before]) |rm| {
            if (try removeIntoArea(arena, io, base, a, rm, &removed)) |f| {
                failure = f;
                break;
            }
        }
    }
    const removed_before = removed.items.len;

    // Fase 3: renomeacoes e movimentos.
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

    // Fase 4: criacoes. Depois das renomeacoes, para que um nome liberado no
    // mesmo passo possa ser reocupado. `exclusive` garante que nenhuma criacao
    // sobrescreva o que ja estiver la.
    if (failure == null) {
        for (p.creates) |c| {
            if (c.kind == .dir) {
                // Pai que ja existe e o caso normal; quem pediu explicitamente
                // um diretorio que ja existe foi barrado antes, na validacao.
                if (dirStatus(io, base, c.path) == .dir) continue;
                base.createDir(io, c.path, .default_dir) catch |err| {
                    failure = .{ .phase = "criar", .detail = c.path, .err = err };
                    break;
                };
            } else {
                var file = base.createFile(io, c.path, .{ .exclusive = true }) catch |err| {
                    failure = .{ .phase = "criar", .detail = c.path, .err = err };
                    break;
                };
                file.close(io);
            }
            try new_entries.append(arena, c);
        }
    }

    // Fase 5: copias. Depois das criacoes; a origem continua existindo (nao
    // participa das fases de rename/remocao). Arquivo e copia de bytes;
    // diretorio e recursivo.
    if (failure == null) {
        for (p.copies) |c| {
            copyEntry(arena, io, base, c) catch |err| {
                failure = .{
                    .phase = "copiar",
                    .detail = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ c.from, c.to }),
                    .err = err,
                };
                break;
            };
            try copied.append(arena, c);
        }
    }

    // Fase 6: remocoes restantes, sempre por ultimo.
    if (failure == null and p.removes.len > p.removes_before) {
        const a = area.?;
        for (p.removes[p.removes_before..]) |rm| {
            if (try removeIntoArea(arena, io, base, a, rm, &removed)) |f| {
                failure = f;
                break;
            }
        }
    }

    var applied: Applied = .{
        .created_dirs = try created.toOwnedSlice(arena),
        .created = try new_entries.toOwnedSlice(arena),
        .renames = try renamed.toOwnedSlice(arena),
        .copied = try copied.toOwnedSlice(arena),
        .removed = try removed.toOwnedSlice(arena),
        .removed_before = removed_before,
        .area = if (area) |a| a.name else null,
    };

    if (failure == null) return .{ .applied = applied, .failure = null };

    const errors = try revert(arena, io, base, applied, if (area) |a| a.dir else null);
    if (errors.len == 0) applied = .{};
    return .{ .failure = failure, .applied = applied, .rollback_errors = errors };
}

/// Move uma entrada para a area de sessao e registra no manifesto. `null`
/// quando tudo passou.
fn removeIntoArea(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    area: *Area,
    rm: plan.Remove,
    removed: *std.ArrayList(Removed),
) Allocator.Error!?Outcome.Failure {
    const stored = try std.fmt.allocPrint(arena, "{d:0>4}", .{rm.id});
    base.renamePreserve(rm.path, area.dir, stored, io) catch |err| {
        return .{ .phase = "remover", .detail = rm.path, .err = err };
    };
    const w = &area.manifest_writer.interface;
    w.print("{s}\x00{s}\x00", .{ stored, rm.path }) catch {};
    w.flush() catch {};
    try removed.append(arena, .{ .id = rm.id, .path = rm.path, .stored = stored });
    return null;
}

/// Copia `c.from` para `c.to` dentro do diretorio-base. Arquivo e copia de
/// bytes (`replace=false` recusa sobrescrever); diretorio e recursivo.
fn copyEntry(arena: Allocator, io: Io, base: Io.Dir, c: plan.Copy) !void {
    switch (c.kind) {
        .dir => {
            try base.createDir(io, c.to, .default_dir);
            try copyDirRecursive(arena, io, base, c.from, c.to);
        },
        else => {
            try base.copyFile(c.from, base, c.to, io, .{ .replace = false });
        },
    }
}

fn copyDirRecursive(arena: Allocator, io: Io, base: Io.Dir, from: []const u8, to: []const u8) !void {
    var src = try base.openDir(io, from, .{ .iterate = true });
    defer src.close(io);

    var it = src.iterate();
    while (it.next(io) catch null) |e| {
        const child_from = try std.fmt.allocPrint(arena, "{s}/{s}", .{ from, e.name });
        const child_to = try std.fmt.allocPrint(arena, "{s}/{s}", .{ to, e.name });
        switch (e.kind) {
            .directory => {
                try base.createDir(io, child_to, .default_dir);
                try copyDirRecursive(arena, io, base, child_from, child_to);
            },
            .sym_link => {
                var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const n = try base.readLink(io, child_from, &buf);
                try base.symLink(io, buf[0..n], child_to, .{});
            },
            else => {
                try base.copyFile(child_from, base, child_to, io, .{ .replace = false });
            },
        }
    }
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

    // Remocoes que vieram por ultimo saem primeiro. As antecipadas so podem
    // voltar depois de desfazer as renomeacoes: um rename pode estar ocupando
    // o caminho original delas.
    if (area_dir) |a| {
        try restoreRemovals(arena, io, base, a, applied.removed, applied.removed_before, applied.removed.len, &errors);
    }

    var c = applied.created.len;
    while (c > 0) {
        c -= 1;
        const entry = applied.created[c];
        if (entry.kind == .dir) {
            base.deleteDir(io, entry.path) catch |err| switch (err) {
                error.FileNotFound => {},
                error.DirNotEmpty => try errors.append(arena, try std.fmt.allocPrint(
                    arena,
                    "{s}/ foi mantido: nao esta mais vazio",
                    .{entry.path},
                )),
                else => try errors.append(arena, try std.fmt.allocPrint(
                    arena,
                    "remover {s}/ criado: {s}",
                    .{ entry.path, @errorName(err) },
                )),
            };
            continue;
        }
        // O undo nao pode apagar o que voce escreveu depois de criar o arquivo.
        const st = base.statFile(io, entry.path, .{ .follow_symlinks = false }) catch |err| {
            if (err != error.FileNotFound) try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "remover {s} criado: {s}",
                .{ entry.path, @errorName(err) },
            ));
            continue;
        };
        if (st.size != 0) {
            try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "{s} foi mantido: nao esta mais vazio",
                .{entry.path},
            ));
            continue;
        }
        base.deleteFile(io, entry.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "remover {s} criado: {s}",
                .{ entry.path, @errorName(err) },
            )),
        };
    }

    // Copias sao materializacoes nossas; o undo as remove por inteiro, arquivo
    // ou arvore. Nao ha o guard de "vazio" da criacao: uma copia nasce com o
    // conteudo da origem.
    var k = applied.copied.len;
    while (k > 0) {
        k -= 1;
        const cp = applied.copied[k];
        if (cp.kind == .dir) {
            base.deleteTree(io, cp.to) catch |err| try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "remover {s}/ copiado: {s}",
                .{ cp.to, @errorName(err) },
            ));
        } else {
            base.deleteFile(io, cp.to) catch |err| switch (err) {
                error.FileNotFound => {},
                else => try errors.append(arena, try std.fmt.allocPrint(
                    arena,
                    "remover {s} copiado: {s}",
                    .{ cp.to, @errorName(err) },
                )),
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

    if (area_dir) |a| {
        try restoreRemovals(arena, io, base, a, applied.removed, 0, applied.removed_before, &errors);
    }

    return errors.toOwnedSlice(arena);
}

/// Restaura o intervalo `[from, to)` de `removed`, em ordem reversa, movendo
/// cada entrada da area de volta para o caminho original.
fn restoreRemovals(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    area: Io.Dir,
    removed: []const Removed,
    from: usize,
    to: usize,
    errors: *std.ArrayList([]const u8),
) Allocator.Error!void {
    var i = to;
    while (i > from) {
        i -= 1;
        const rm = removed[i];
        area.renamePreserve(rm.stored, base, rm.path, io) catch |err| {
            try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "restaurar {s} de {s}: {s}",
                .{ rm.path, rm.stored, @errorName(err) },
            ));
        };
    }
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
    const res = try plan.build(arena, originals, edits, &.{}, .{});
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

test "remover e renomear para o nome liberado na mesma rodada" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("a.txt", "antigo");
    try h.touch("b.txt", "novo");

    // ID 1 removido (fora do buffer); ID 2 renomeado para "a.txt".
    const originals = [_]plan.Original{
        .{ .id = 1, .path = "a.txt", .kind = .file },
        .{ .id = 2, .path = "b.txt", .kind = .file },
    };
    const edits = [_]plan.Edit{.{ .id = 2, .path = "a.txt", .line = 2 }};
    const p = try planFor(h.a(), &originals, &edits);
    try testing.expectEqual(@as(usize, 1), p.removes_before);
    try testing.expectEqual(@as(usize, 1), p.removes.len);
    try testing.expectEqual(@as(usize, 1), p.renames.len);

    const name = try areaName(h.a(), 4247);
    var area = try openArea(h.a(), io, h.dir(), name);
    defer area.close(io);

    const outcome = try apply(h.a(), io, h.dir(), p, &area);
    try testing.expect(outcome.failure == null);
    try testing.expectEqualStrings("novo", try h.read("a.txt"));
    try testing.expect(!h.exists("b.txt"));
    try testing.expect(h.exists(".lst-f-4247/0001"));

    // O undo restaura a remocao depois de desfazer o rename.
    const errors = try revert(h.a(), io, h.dir(), outcome.applied, area.dir);
    try testing.expectEqual(@as(usize, 0), errors.len);
    try testing.expectEqualStrings("antigo", try h.read("a.txt"));
    try testing.expectEqualStrings("novo", try h.read("b.txt"));
}

test "rollback restaura a remocao antecipada depois do rename" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("a", "A");
    try h.touch("b", "B");
    try h.touch("c", "C");

    const name = try areaName(h.a(), 4248);
    var area = try openArea(h.a(), io, h.dir(), name);
    defer area.close(io);
    // Colisao plantada na area: a remocao de "c", que vem por ultimo, falha.
    try h.touch(".lst-f-4248/0003", "impostor");

    const originals = [_]plan.Original{
        .{ .id = 1, .path = "a", .kind = .file },
        .{ .id = 2, .path = "b", .kind = .file },
        .{ .id = 3, .path = "c", .kind = .file },
    };
    // Remove "a" e "c"; renomeia "b" -> "a". A remocao de "a" e antecipada.
    const edits = [_]plan.Edit{.{ .id = 2, .path = "a", .line = 2 }};
    const p = try planFor(h.a(), &originals, &edits);
    try testing.expectEqual(@as(usize, 1), p.removes_before);
    try testing.expectEqual(@as(usize, 2), p.removes.len);

    const outcome = try apply(h.a(), io, h.dir(), p, &area);
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(@as(usize, 0), outcome.rollback_errors.len);
    try testing.expectEqualStrings("A", try h.read("a"));
    try testing.expectEqualStrings("B", try h.read("b"));
    try testing.expectEqualStrings("C", try h.read("c"));
}

test "copia arquivo e desfaz no undo" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("a.txt", "conteudo A");
    const originals = [_]plan.Original{.{ .id = 1, .path = "a.txt", .kind = .file }};
    const edits = [_]plan.Edit{
        .{ .id = 1, .path = "a.txt", .line = 1 },
        .{ .id = 1, .path = "b.txt", .line = 2 },
    };
    const p = try planFor(h.a(), &originals, &edits);
    try testing.expectEqual(@as(usize, 1), p.copies.len);

    const outcome = try apply(h.a(), io, h.dir(), p, null);
    try testing.expect(outcome.failure == null);
    try testing.expectEqualStrings("conteudo A", try h.read("a.txt"));
    try testing.expectEqualStrings("conteudo A", try h.read("b.txt"));

    const errors = try revert(h.a(), io, h.dir(), outcome.applied, null);
    try testing.expectEqual(@as(usize, 0), errors.len);
    try testing.expect(h.exists("a.txt"));
    try testing.expect(!h.exists("b.txt"));
}

test "copia diretorio recursivo e desfaz" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.dir().createDirPath(io, "src/sub");
    try h.touch("src/a.txt", "1");
    try h.touch("src/sub/b.txt", "2");

    const originals = [_]plan.Original{.{ .id = 1, .path = "src", .kind = .dir }};
    const edits = [_]plan.Edit{
        .{ .id = 1, .path = "src", .line = 1 },
        .{ .id = 1, .path = "dst", .line = 2 },
    };
    const p = try planFor(h.a(), &originals, &edits);
    try testing.expectEqual(@as(usize, 1), p.copies.len);

    const outcome = try apply(h.a(), io, h.dir(), p, null);
    try testing.expect(outcome.failure == null);
    try testing.expectEqualStrings("1", try h.read("dst/a.txt"));
    try testing.expectEqualStrings("2", try h.read("dst/sub/b.txt"));

    const errors = try revert(h.a(), io, h.dir(), outcome.applied, null);
    try testing.expectEqual(@as(usize, 0), errors.len);
    try testing.expect(h.exists("src"));
    try testing.expect(!h.exists("dst"));
}

test "falha na remocao desfaz a copia ja feita" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("a.txt", "A");
    try h.touch("um", "1");

    const name = try areaName(h.a(), 4249);
    var area = try openArea(h.a(), io, h.dir(), name);
    defer area.close(io);
    // Colisao plantada na area: a remocao, que vem depois da copia, falha.
    try h.touch(".lst-f-4249/0002", "impostor");

    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{},
        .creates = &.{},
        .copies = &.{.{ .id = 1, .from = "a.txt", .to = "copia.txt", .kind = .file }},
        .removes = &.{.{ .id = 2, .path = "um", .kind = .file }},
        .moves = &.{},
        .unchanged = 0,
    };
    const outcome = try apply(h.a(), io, h.dir(), p, &area);
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(@as(usize, 0), outcome.rollback_errors.len);
    try testing.expect(!h.exists("copia.txt"));
    try testing.expect(h.exists("a.txt"));
    try testing.expect(h.exists("um"));
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

test "cria arquivo e diretorio no disco" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{},
        .creates = &.{
            .{ .path = "docs", .kind = .dir, .implicit = true },
            .{ .path = "docs/nota.md", .kind = .file },
            .{ .path = "vazio", .kind = .dir },
        },
        .removes = &.{},
        .moves = &.{},
        .unchanged = 0,
    };
    const outcome = try apply(h.a(), io, h.dir(), p, null);
    try testing.expect(outcome.failure == null);
    try testing.expectEqual(@as(usize, 3), outcome.applied.created.len);
    try testing.expect(h.exists("docs/nota.md"));
    try testing.expect(h.exists("vazio"));
    try testing.expectEqualStrings("", try h.read("docs/nota.md"));
}

test "criacao nunca sobrescreve o que ja esta la" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("ocupado.txt", "nao me trunque");

    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{},
        .creates = &.{.{ .path = "ocupado.txt", .kind = .file }},
        .removes = &.{},
        .moves = &.{},
        .unchanged = 0,
    };
    const outcome = try apply(h.a(), io, h.dir(), p, null);
    try testing.expect(outcome.failure != null);
    try testing.expectEqualStrings("nao me trunque", try h.read("ocupado.txt"));
}

test "falha depois da criacao desfaz o que foi criado" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("um", "1");

    const name = try areaName(h.a(), 4246);
    var area = try openArea(h.a(), io, h.dir(), name);
    defer area.close(io);
    // Colisao plantada na area: a remocao, que vem por ultimo, vai falhar.
    try h.touch(".lst-f-4246/0001", "impostor");

    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{},
        .creates = &.{
            .{ .path = "novo", .kind = .dir, .implicit = true },
            .{ .path = "novo/x.txt", .kind = .file },
        },
        .removes = &.{.{ .id = 1, .path = "um", .kind = .file }},
        .moves = &.{},
        .unchanged = 0,
    };
    const outcome = try apply(h.a(), io, h.dir(), p, &area);
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(@as(usize, 0), outcome.rollback_errors.len);
    try testing.expect(!h.exists("novo/x.txt"));
    try testing.expect(!h.exists("novo"));
    try testing.expect(h.exists("um"));
}

test "desfazer mantem o arquivo criado que deixou de estar vazio" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("vazio.md", "");
    try h.touch("escrito.md", "conteudo que voce digitou depois");

    const applied: Applied = .{
        .created = &.{
            .{ .path = "vazio.md", .kind = .file },
            .{ .path = "escrito.md", .kind = .file },
        },
    };
    const errors = try revert(h.a(), io, h.dir(), applied, null);
    try testing.expectEqual(@as(usize, 1), errors.len);
    try testing.expect(!h.exists("vazio.md"));
    try testing.expect(h.exists("escrito.md"));
}
