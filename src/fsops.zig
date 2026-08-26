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

pub fn processAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    return true;
}

