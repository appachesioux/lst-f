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

/// Entrada que saiu de outra pasta por copia + remocao, porque origem e destino
/// estao em filesystems diferentes e `rename` nao atravessa ponto de montagem.
/// Guarda o que o rollback precisa para devolve-la: a area onde ela ficou, o
/// nome la dentro e o nome original.
pub const MovedOut = struct {
    /// Diretorio de origem, absoluto.
    dir: []const u8,
    /// Area de sessao dentro dele.
    area_name: []const u8,
    stored: []const u8,
    /// Nome original dentro do diretorio de origem.
    name: []const u8,
};

/// Pasta de origem de um movimento entre filesystems, com a area de sessao
/// dela ja aberta. Quem abre e a CLI, que e quem registra as areas para a
/// limpeza no fim -- uma area aberta aqui dentro vazaria no diretorio alheio.
pub const Source = struct {
    /// Diretorio de origem, absoluto, como aparece em `dirname(copy.from_abs)`.
    dir: []const u8,
    handle: Io.Dir,
    area: *Area,
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
    /// Origens que sairam da pasta delas por copia + remocao (cross-device).
    moved_out: []const MovedOut = &.{},
    area: ?[]const u8 = null,

    pub fn isEmpty(a: Applied) bool {
        return a.created_dirs.len == 0 and a.created.len == 0 and
            a.renames.len == 0 and a.copied.len == 0 and a.removed.len == 0 and
            a.moved_out.len == 0;
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

/// Numero do dispositivo do filesystem que contem `path`. `null` quando nao da
/// para saber -- ai quem chama assume o caso conservador. E o que decide se um
/// movimento entre pastas cabe num `rename` ou precisa de copia + remocao.
pub fn deviceOf(io: Io, path: []const u8) ?u64 {
    if (@import("builtin").os.tag != .linux) return null;
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return null;
    defer dir.close(io);
    const linux = std.os.linux;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return (@as(u64, stx.dev_major) << 32) | stx.dev_minor;
}

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
    /// Pastas de origem dos movimentos entre filesystems, com a area delas
    /// aberta. Vazio quando nao ha nenhum.
    sources: []const Source,
) Allocator.Error!Outcome {
    var created: std.ArrayList([]const u8) = .empty;
    var new_entries: std.ArrayList(plan.Create) = .empty;
    var renamed: std.ArrayList(plan.Rename) = .empty;
    var removed: std.ArrayList(Removed) = .empty;
    var copied: std.ArrayList(plan.Copy) = .empty;
    var moved_out: std.ArrayList(MovedOut) = .empty;

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
                    failure = .{ .phase = "criar diretorio", .detail = c.path, .err = err };
                    break;
                };
            } else if (c.kind == .symlink) {
                const target = c.target orelse "";
                base.symLink(io, target, c.path, .{}) catch |err| {
                    failure = .{
                        .phase = "criar symlink",
                        .detail = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ c.path, target }),
                        .err = err,
                    };
                    break;
                };
            } else if (c.kind == .hardlink) {
                const target = c.target orelse "";
                base.hardLink(target, base, c.path, io, .{}) catch |err| {
                    failure = .{
                        .phase = "criar hardlink",
                        .detail = try std.fmt.allocPrint(arena, "{s} => {s}", .{ c.path, target }),
                        .err = err,
                    };
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

    // Fase 5: copias e movimentos vindos de outro buffer de diretorio. Depois
    // das criacoes. Na copia a origem continua existindo (nao participa das
    // fases de rename/remocao); no movimento ela sai do lugar por `rename`,
    // que e atomico e volta atras sem area de sessao -- o undo so renomeia de
    // volta.
    if (failure == null) {
        for (p.copies) |c| {
            const outcome = if (c.cut and !c.cross_device)
                moveEntry(io, base, c)
            else
                copyEntry(arena, io, base, c);
            outcome catch |err| {
                failure = .{
                    .phase = if (c.cut) "mover" else "copiar",
                    .detail = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ c.from, c.to }),
                    .err = err,
                };
                break;
            };
            try copied.append(arena, c);
            // Movimento entre filesystems: a copia ja esta aqui, falta tirar a
            // origem de la. Vai para a area de sessao da pasta dela, nunca
            // apagada -- a promessa do `:undo` nao muda por causa do mount.
            if (c.cut and c.cross_device) {
                if (try removeSource(arena, io, c, sources, &moved_out)) |f| {
                    failure = f;
                    break;
                }
            }
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
        .moved_out = try moved_out.toOwnedSlice(arena),
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

/// Copia para `c.to` dentro do diretorio-base. Arquivo e copia de bytes
/// (`replace=false` recusa sobrescrever); diretorio e recursivo. A origem e o
/// proprio base, exceto quando `from_abs` esta presente: linha colada de outro
/// buffer de diretorio, cuja origem vive fora daqui.
fn copyEntry(arena: Allocator, io: Io, base: Io.Dir, c: plan.Copy) !void {
    const src = if (c.from_abs != null) Io.Dir.cwd() else base;
    const from = c.from_abs orelse c.from;
    switch (c.kind) {
        .dir => {
            try base.createDir(io, c.to, .default_dir);
            try copyDirRecursive(arena, io, src, base, from, c.to);
        },
        else => {
            try src.copyFile(from, base, c.to, io, .{ .replace = false });
        },
    }
}

/// Devolve para a pasta de origem uma entrada que saiu por copia + remocao.
/// Abre a pasta e a area pelo caminho, porque o rollback pode acontecer numa
/// rodada em que aqueles descritores ja se foram (`:undo`).
fn restoreMovedOut(io: Io, mv: MovedOut) !void {
    var dir = try Io.Dir.cwd().openDir(io, mv.dir, .{});
    defer dir.close(io);
    var area_dir = try dir.openDir(io, mv.area_name, .{});
    defer area_dir.close(io);
    try area_dir.renamePreserve(mv.stored, dir, mv.name, io);
}

/// Tira a origem de um movimento entre filesystems da pasta dela, para a area
/// de sessao daquela pasta. `null` quando passou.
fn removeSource(
    arena: Allocator,
    io: Io,
    c: plan.Copy,
    sources: []const Source,
    out: *std.ArrayList(MovedOut),
) Allocator.Error!?Outcome.Failure {
    const abs = c.from_abs orelse return null;
    const dir = std.fs.path.dirname(abs) orelse "/";
    const name = std.fs.path.basename(abs);
    for (sources) |src| {
        if (!std.mem.eql(u8, src.dir, dir)) continue;
        const stored = try std.fmt.allocPrint(arena, "{d:0>4}", .{c.id});
        src.handle.renamePreserve(name, src.area.dir, stored, io) catch |err| {
            return .{ .phase = "remover a origem do movimento", .detail = abs, .err = err };
        };
        const w = &src.area.manifest_writer.interface;
        w.print("{s}\x00{s}\x00", .{ stored, name }) catch {};
        w.flush() catch {};
        try out.append(arena, .{
            .dir = src.dir,
            .area_name = src.area.name,
            .stored = stored,
            .name = name,
        });
        return null;
    }
    // Sem area para a pasta de origem a copia ja aconteceu, mas a origem nao
    // pode sair: recusar aqui deixa o rollback limpar o que foi materializado.
    return .{ .phase = "remover a origem do movimento", .detail = abs, .err = error.AreaUnavailable };
}

/// Movimento vindo de outro buffer de diretorio: a entrada sai da pasta de
/// origem e entra nesta. `renamePreserve` e `RENAME_NOREPLACE`, entao o destino
/// precisa estar livre -- o plano garante isso antecipando a remocao que o
/// libera, ou recusando o nome que continua ocupado. Origem e destino em
/// filesystems diferentes dao `RenameAcrossMountPoints`, que sobe como falha
/// sem ter mexido em nada.
fn moveEntry(io: Io, base: Io.Dir, c: plan.Copy) !void {
    const abs = c.from_abs orelse return error.MissingSource;
    const parent = std.fs.path.dirname(abs) orelse "/";
    var src = try Io.Dir.cwd().openDir(io, parent, .{});
    defer src.close(io);
    try src.renamePreserve(std.fs.path.basename(abs), base, c.to, io);
}

fn copyDirRecursive(arena: Allocator, io: Io, src_root: Io.Dir, base: Io.Dir, from: []const u8, to: []const u8) !void {
    var src = try src_root.openDir(io, from, .{ .iterate = true });
    defer src.close(io);

    var it = src.iterate();
    while (it.next(io) catch null) |e| {
        const child_from = try std.fmt.allocPrint(arena, "{s}/{s}", .{ from, e.name });
        const child_to = try std.fmt.allocPrint(arena, "{s}/{s}", .{ to, e.name });
        switch (e.kind) {
            .directory => {
                try base.createDir(io, child_to, .default_dir);
                try copyDirRecursive(arena, io, src_root, base, child_from, child_to);
            },
            .sym_link => {
                var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const n = try src_root.readLink(io, child_from, &buf);
                try base.symLink(io, buf[0..n], child_to, .{});
            },
            else => {
                try src_root.copyFile(child_from, base, child_to, io, .{ .replace = false });
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
        if (entry.kind == .symlink or entry.kind == .hardlink) {
            base.deleteFile(io, entry.path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => try errors.append(arena, try std.fmt.allocPrint(
                    arena,
                    "remover {s} criado: {s}",
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
    // conteudo da origem. Movimento vindo de outra pasta nao materializou nada:
    // o undo dele e o rename de volta, senao apagaria o arquivo original.
    // Origens que sairam da pasta delas por copia + remocao voltam da area
    // daquela pasta. Antes de apagar a copia, porque e a copia que ainda
    // carrega o conteudo caso a volta falhe.
    var m = applied.moved_out.len;
    while (m > 0) {
        m -= 1;
        const mv = applied.moved_out[m];
        restoreMovedOut(io, mv) catch |err| {
            try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "devolver {s} para {s}: {s}",
                .{ mv.name, mv.dir, @errorName(err) },
            ));
        };
    }

    var k = applied.copied.len;
    while (k > 0) {
        k -= 1;
        const cp = applied.copied[k];
        // O movimento entre filesystems e copia + remocao: a copia daqui sai
        // como qualquer outra, e a origem ja voltou acima.
        if (cp.cut and !cp.cross_device) {
            const abs = cp.from_abs orelse continue;
            const parent = std.fs.path.dirname(abs) orelse "/";
            var src = Io.Dir.cwd().openDir(io, parent, .{}) catch |err| {
                try errors.append(arena, try std.fmt.allocPrint(
                    arena,
                    "devolver {s} para {s}: {s}",
                    .{ cp.to, parent, @errorName(err) },
                ));
                continue;
            };
            defer src.close(io);
            base.renamePreserve(cp.to, src, std.fs.path.basename(abs), io) catch |err| {
                try errors.append(arena, try std.fmt.allocPrint(
                    arena,
                    "devolver {s} para {s}: {s}",
                    .{ cp.to, abs, @errorName(err) },
                ));
            };
            continue;
        }
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
