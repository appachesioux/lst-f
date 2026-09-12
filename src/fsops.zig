//! Execucao ordenada do plano, retencao na lixeira, rollback e relatorio.
//!
//! Remocao nao apaga: o que sai vai para a lixeira, uma pasta so
//! (`~/.local/share/lst-f/trash`), por `rename()` quando e o mesmo filesystem e
//! por copia quando nao e -- a protecao nao depende da tabela de montagem. A
//! lixeira sobrevive a sessao; a poda por idade e quem a esvazia. Movimento nao
//! passa por ela: o arquivo esta no destino, nao foi perdido.
//!
//! A excecao e operar dentro da propria lixeira, onde remocao e definitiva --
//! senao seria renomear para dentro de si mesma, e nao haveria como esvaziar.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const plan = @import("plan.zig");

pub const Removed = struct {
    id: u32,
    /// Caminho original, relativo ao diretorio-base.
    path: []const u8,
    /// Nome dentro da lixeira: o basename original, com sufixo `-01` quando ja
    /// havia outro igual la -- a mesma convencao da copia. Vazio na remocao
    /// definitiva.
    stored: []const u8,
    kind: plan.Kind,
    /// Entrou na lixeira por copia (outro filesystem). O undo volta copiando e
    /// apaga a copia de la; `rename` nao serviria pelo mesmo motivo de antes.
    copied: bool = false,
    /// Removida em definitivo (dentro da propria lixeira): nada a restaurar.
    permanent: bool = false,
};

/// Entrada que saiu de outra pasta por copia + remocao, porque origem e destino
/// estao em filesystems diferentes e `rename` nao atravessa ponto de montagem.
/// A origem sai por `unlink`: movimento nao e perda, o arquivo esta no destino.
/// E de la que o undo o traz de volta, o que exige saber onde a copia ficou.
pub const MovedOut = struct {
    /// Diretorio de origem, absoluto.
    dir: []const u8,
    /// Nome original dentro do diretorio de origem.
    name: []const u8,
    /// Onde a copia ficou, relativo ao diretorio-base.
    to: []const u8,
    kind: plan.Kind,
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

pub const TrashError = error{
    /// A lixeira nao pode receber (sem HOME, sem permissao, disco cheio). A
    /// remocao e recusada: cair para remocao definitiva faria a seguranca
    /// depender de circunstancia.
    TrashUnavailable,
};

/// A lixeira aberta. Uma por sessao, uma por usuario -- o mesmo lugar sempre.
pub const Trash = struct {
    /// Caminho absoluto, para o relatorio e para o `:trash`.
    path: []const u8,
    dir: Io.Dir,
    /// Prefixo do nome temporario da copia cross-device, com o PID desta
    /// sessao. Parcial de crash fica assim: oculto da listagem (dotfile),
    /// reservado pelo parser e varrido pela poda quando o PID morre.
    temp_prefix: []const u8,

    pub fn close(t: *Trash, io: Io) void {
        t.dir.close(io);
    }
};

/// Para onde vai o que for removido nesta aplicacao.
pub const Retention = union(enum) {
    trash: *Trash,
    /// O diretorio-base e a propria lixeira: remocao e definitiva.
    permanent,
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

/// Abre a lixeira, criando o caminho inteiro sob demanda com 0700. Qualquer
/// falha vira `TrashUnavailable`, que a CLI traduz em recusa explicita da
/// remocao -- nunca em remocao definitiva.
pub fn openTrash(
    arena: Allocator,
    io: Io,
    /// Contra quem `path` e resolvido: a CLI passa `cwd` e o caminho absoluto;
    /// o teste passa o diretorio temporario e um nome relativo.
    root: Io.Dir,
    path: []const u8,
    pid: std.posix.pid_t,
) (Allocator.Error || TrashError)!Trash {
    const only_user: Io.File.Permissions = @enumFromInt(0o700);
    _ = root.createDirPathStatus(io, path, only_user) catch return error.TrashUnavailable;
    const dir = root.openDir(io, path, .{ .iterate = true }) catch return error.TrashUnavailable;
    return .{
        .path = path,
        .dir = dir,
        .temp_prefix = try std.fmt.allocPrint(arena, "{s}{d}-", .{ plan.temp_prefix, pid }),
    };
}

/// Idade maxima na lixeira. Depois disso a poda apaga, na abertura da sessao.
pub const max_age_s: i64 = 30 * 24 * 60 * 60;

pub const Prune = struct {
    /// Entradas apagadas por idade.
    expired: usize = 0,
    /// Temporarios de copia interrompida, de sessao que nao esta mais rodando.
    temps: usize = 0,

    pub fn isEmpty(p: Prune) bool {
        return p.expired == 0 and p.temps == 0;
    }
};

/// Esvazia o que passou da idade e varre temporario orfao. A idade e o `ctime`,
/// que o `rename` para a lixeira define -- e a mesma coluna SAVED que a
/// listagem mostra, entao o que se ve na lixeira e o relogio que conta aqui.
/// `now_s` entra por parametro para o teste poder envelhecer a lixeira.
pub fn pruneTrash(
    io: Io,
    trash: Io.Dir,
    now_s: i64,
    age_s: i64,
    self_pid: std.posix.pid_t,
) Prune {
    var out: Prune = .{};
    var it = trash.iterate();
    while (it.next(io) catch null) |e| {
        const temp = std.mem.startsWith(u8, e.name, plan.temp_prefix);
        if (temp) {
            // Copia em andamento de uma sessao viva nao se toca.
            const rest = e.name[plan.temp_prefix.len..];
            const dash = std.mem.indexOfScalar(u8, rest, '-') orelse continue;
            const pid = std.fmt.parseInt(std.posix.pid_t, rest[0..dash], 10) catch continue;
            if (pid == self_pid or processAlive(pid)) continue;
        } else {
            const st = trash.statFile(io, e.name, .{ .follow_symlinks = false }) catch continue;
            if (now_s - st.ctime.toSeconds() <= age_s) continue;
        }
        const gone = if (e.kind == .directory)
            trash.deleteTree(io, e.name)
        else
            trash.deleteFile(io, e.name);
        gone catch continue;
        if (temp) out.temps += 1 else out.expired += 1;
    }
    return out;
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
    /// Para onde vai o que for removido. `null` so quando o plano nao remove
    /// nada -- quem chama recusa a remocao antes de chegar aqui se a lixeira
    /// nao pode receber.
    retention: ?Retention,
) Allocator.Error!Outcome {
    var created: std.ArrayList([]const u8) = .empty;
    var new_entries: std.ArrayList(plan.Create) = .empty;
    var renamed: std.ArrayList(plan.Rename) = .empty;
    var removed: std.ArrayList(Removed) = .empty;
    var copied: std.ArrayList(plan.Copy) = .empty;
    var moved_out: std.ArrayList(MovedOut) = .empty;

    var failure: ?Outcome.Failure = null;

    // Plano que remove sem retencao nao existe: quem chama recusa antes. Vale
    // como guarda para nao apagar nada por engano se um chamador novo esquecer.
    if (p.removes.len > 0 and retention == null) return .{
        .applied = .{},
        .failure = .{
            .phase = "remover",
            .detail = p.removes[0].path,
            .err = error.TrashUnavailable,
        },
    };

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
        for (p.removes[0..p.removes_before]) |rm| {
            if (try remove(arena, io, base, retention.?, rm, &removed)) |f| {
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
    // que e atomico e volta atras sem retencao nenhuma -- o undo so renomeia de
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
            // origem de la. Sai por `unlink`, sem passar pela lixeira: o
            // arquivo esta no destino, nao foi perdido -- e e de la que o undo
            // o traz de volta.
            if (c.cut and c.cross_device) {
                if (try removeSource(arena, io, c, &moved_out)) |f| {
                    failure = f;
                    break;
                }
            }
        }
    }

    // Fase 6: remocoes restantes, sempre por ultimo.
    if (failure == null and p.removes.len > p.removes_before) {
        for (p.removes[p.removes_before..]) |rm| {
            if (try remove(arena, io, base, retention.?, rm, &removed)) |f| {
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
    };

    if (failure == null) return .{ .applied = applied, .failure = null };

    const trash_dir: ?Io.Dir = if (retention) |r| switch (r) {
        .trash => |t| t.dir,
        .permanent => null,
    } else null;
    const errors = try revert(arena, io, base, applied, trash_dir);
    if (errors.len == 0) applied = .{};
    return .{ .failure = failure, .applied = applied, .rollback_errors = errors };
}

/// Remove uma entrada, para onde a retencao mandar. `null` quando passou.
fn remove(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    retention: Retention,
    rm: plan.Remove,
    removed: *std.ArrayList(Removed),
) Allocator.Error!?Outcome.Failure {
    switch (retention) {
        .trash => |t| return removeIntoTrash(arena, io, base, t, rm, removed),
        .permanent => {
            deleteEntry(io, base, rm.path, rm.kind) catch |err| {
                return .{ .phase = "remover", .detail = rm.path, .err = err };
            };
            try removed.append(arena, .{
                .id = rm.id,
                .path = rm.path,
                .stored = "",
                .kind = rm.kind,
                .permanent = true,
            });
            return null;
        },
    }
}

fn deleteEntry(io: Io, base: Io.Dir, path: []const u8, kind: plan.Kind) !void {
    if (kind == .dir) return base.deleteTree(io, path);
    return base.deleteFile(io, path);
}

/// Manda a entrada para a lixeira com o nome original, sufixando quando o nome
/// ja esta ocupado la. Mesmo filesystem e `rename`; outro filesystem e copia,
/// porque a protecao nao pode depender de onde o arquivo mora.
fn removeIntoTrash(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    t: *Trash,
    rm: plan.Remove,
    removed: *std.ArrayList(Removed),
) Allocator.Error!?Outcome.Failure {
    const name = std.fs.path.basename(rm.path);
    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        const stored = try freeName(arena, io, t.dir, name, rm.kind == .dir);
        base.renamePreserve(rm.path, t.dir, stored, io) catch |err| switch (err) {
            // Corrida com outra sessao mandando o mesmo nome para ca: tenta o
            // sufixo seguinte. `renamePreserve` e RENAME_NOREPLACE, entao
            // ninguem sobrescreve ninguem.
            error.PathAlreadyExists => continue,
            error.CrossDevice => {
                copyIntoTrash(arena, io, base, t, rm, stored) catch |cerr| {
                    return .{ .phase = "remover", .detail = rm.path, .err = cerr };
                };
                try removed.append(arena, .{
                    .id = rm.id,
                    .path = rm.path,
                    .stored = stored,
                    .kind = rm.kind,
                    .copied = true,
                });
                return null;
            },
            else => return .{ .phase = "remover", .detail = rm.path, .err = err },
        };
        try removed.append(arena, .{
            .id = rm.id,
            .path = rm.path,
            .stored = stored,
            .kind = rm.kind,
        });
        return null;
    }
    return .{ .phase = "remover", .detail = rm.path, .err = error.PathAlreadyExists };
}

/// Nome livre na lixeira: o original, ou `nome-01`, `nome-02`... -- o sufixo da
/// copia (`plan.suffixed`), para nao haver duas convencoes de nome no projeto.
fn freeName(
    arena: Allocator,
    io: Io,
    trash: Io.Dir,
    name: []const u8,
    is_dir: bool,
) Allocator.Error![]const u8 {
    var candidate = name;
    var n: u32 = 1;
    while (n < 100) : (n += 1) {
        _ = trash.statFile(io, candidate, .{ .follow_symlinks = false }) catch return candidate;
        candidate = try plan.suffixed(arena, name, n, is_dir);
    }
    return candidate;
}

/// Copia para a lixeira quando ela esta em outro filesystem, e so entao apaga a
/// origem. A copia vai para um nome temporario e chega ao nome final por
/// `rename`: parcial de crash nunca aparece como entrada da lixeira, e e o
/// rename final que define o `ctime` de onde a poda conta os 30 dias.
fn copyIntoTrash(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    t: *Trash,
    rm: plan.Remove,
    stored: []const u8,
) !void {
    const temp = try std.fmt.allocPrint(arena, "{s}{s}", .{ t.temp_prefix, stored });
    errdefer deleteEntry(io, t.dir, temp, rm.kind) catch {};
    if (rm.kind == .dir) {
        try t.dir.createDir(io, temp, .default_dir);
        try copyDirRecursive(arena, io, base, t.dir, rm.path, temp);
    } else {
        try base.copyFile(rm.path, t.dir, temp, io, .{ .replace = false });
    }
    try t.dir.renamePreserve(temp, t.dir, stored, io);
    // A copia esta inteira na lixeira: agora a origem pode sair.
    deleteEntry(io, base, rm.path, rm.kind) catch |err| {
        // Origem intacta e copia na lixeira: apagar a copia deixa o estado
        // como estava, que e o desfecho certo para quem falhou aqui.
        deleteEntry(io, t.dir, stored, rm.kind) catch {};
        return err;
    };
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

/// Devolve para a pasta de origem uma entrada que saiu por copia + remocao. A
/// unica instancia do arquivo e a copia no destino, entao a volta e copiar de
/// la -- quem apaga essa copia e o laco de copias do `revert`, depois daqui.
/// Abre a pasta pelo caminho porque o `:undo` roda numa rodada em que o
/// descritor da origem ja se foi.
fn restoreMovedOut(arena: Allocator, io: Io, base: Io.Dir, mv: MovedOut) !void {
    var dir = try Io.Dir.cwd().openDir(io, mv.dir, .{});
    defer dir.close(io);
    if (mv.kind == .dir) {
        try dir.createDir(io, mv.name, .default_dir);
        try copyDirRecursive(arena, io, base, dir, mv.to, mv.name);
    } else {
        try base.copyFile(mv.to, dir, mv.name, io, .{ .replace = false });
    }
}

/// Tira a origem de um movimento entre filesystems da pasta dela. Definitiva,
/// sem passar pela lixeira: o arquivo esta no destino, nao foi perdido.
/// `null` quando passou.
fn removeSource(
    arena: Allocator,
    io: Io,
    c: plan.Copy,
    out: *std.ArrayList(MovedOut),
) Allocator.Error!?Outcome.Failure {
    const abs = c.from_abs orelse return null;
    const dir = std.fs.path.dirname(abs) orelse "/";
    const name = std.fs.path.basename(abs);
    var src = Io.Dir.cwd().openDir(io, dir, .{}) catch |err| {
        return .{ .phase = "remover a origem do movimento", .detail = abs, .err = err };
    };
    defer src.close(io);
    deleteEntry(io, src, name, c.kind) catch |err| {
        return .{ .phase = "remover a origem do movimento", .detail = abs, .err = err };
    };
    try out.append(arena, .{ .dir = dir, .name = name, .to = c.to, .kind = c.kind });
    return null;
}

/// Movimento vindo de outro buffer de diretorio: a entrada sai da pasta de
/// origem e entra nesta. `renamePreserve` e `RENAME_NOREPLACE`, entao o destino
/// precisa estar livre -- o plano garante isso antecipando a remocao que o
/// libera, ou recusando o nome que continua ocupado. Origem e destino em
/// filesystems diferentes dao `error.CrossDevice`, que sobe como falha
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
    trash_dir: ?Io.Dir,
) Allocator.Error![]const []const u8 {
    var errors: std.ArrayList([]const u8) = .empty;

    // Remocoes que vieram por ultimo saem primeiro. As antecipadas so podem
    // voltar depois de desfazer as renomeacoes: um rename pode estar ocupando
    // o caminho original delas.
    try restoreRemovals(arena, io, base, trash_dir, applied.removed, applied.removed_before, applied.removed.len, &errors);

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
    var kept: std.StringHashMapUnmanaged(void) = .empty;
    var m = applied.moved_out.len;
    while (m > 0) {
        m -= 1;
        const mv = applied.moved_out[m];
        restoreMovedOut(arena, io, base, mv) catch |err| {
            // A copia no destino e a unica instancia do arquivo: se a volta
            // falhou, ela nao pode ser apagada abaixo.
            try kept.put(arena, mv.to, {});
            try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "devolver {s} para {s}: {s}; mantive {s}",
                .{ mv.name, mv.dir, @errorName(err), mv.to },
            ));
        };
    }

    var k = applied.copied.len;
    while (k > 0) {
        k -= 1;
        const cp = applied.copied[k];
        // O movimento entre filesystems e copia + remocao: a copia daqui sai
        // como qualquer outra, e a origem ja voltou acima -- salvo quando a
        // volta falhou, e ai esta copia e tudo que restou do arquivo.
        if (kept.contains(cp.to)) continue;
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

    try restoreRemovals(arena, io, base, trash_dir, applied.removed, 0, applied.removed_before, &errors);

    return errors.toOwnedSlice(arena);
}

/// Restaura o intervalo `[from, to)` de `removed`, em ordem reversa, tirando
/// cada entrada da lixeira de volta para o caminho original. O que entrou na
/// lixeira por copia volta copiando; o que foi removido em definitivo (dentro
/// da propria lixeira) nao volta, e isso aparece no relatorio.
fn restoreRemovals(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    trash_dir: ?Io.Dir,
    removed: []const Removed,
    from: usize,
    to: usize,
    errors: *std.ArrayList([]const u8),
) Allocator.Error!void {
    var i = to;
    while (i > from) {
        i -= 1;
        const rm = removed[i];
        if (rm.permanent) {
            try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "{s} nao volta: foi removido em definitivo",
                .{rm.path},
            ));
            continue;
        }
        const trash = trash_dir orelse continue;
        restoreRemoval(arena, io, base, trash, rm) catch |err| {
            try errors.append(arena, try std.fmt.allocPrint(
                arena,
                "restaurar {s} de {s}: {s}",
                .{ rm.path, rm.stored, @errorName(err) },
            ));
        };
    }
}

fn restoreRemoval(arena: Allocator, io: Io, base: Io.Dir, trash: Io.Dir, rm: Removed) !void {
    if (!rm.copied) return trash.renamePreserve(rm.stored, base, rm.path, io);
    if (rm.kind == .dir) {
        try base.createDir(io, rm.path, .default_dir);
        try copyDirRecursive(arena, io, trash, base, rm.stored, rm.path);
    } else {
        try trash.copyFile(rm.stored, base, rm.path, io, .{ .replace = false });
    }
    // A copia voltou inteira: agora a da lixeira pode sair.
    try deleteEntry(io, trash, rm.stored, rm.kind);
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

/// Quantos bytes a entrada ocupa, somando a subarvore quando e diretorio. E o
/// volume que a confirmacao mostra quando a remocao vai ter de copiar.
pub fn entrySize(io: Io, base: Io.Dir, path: []const u8, kind: plan.Kind) u64 {
    if (kind != .dir) {
        const st = base.statFile(io, path, .{ .follow_symlinks = false }) catch return 0;
        return st.size;
    }
    var dir = base.openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch return 0;
    defer dir.close(io);
    return sizeOfDir(io, dir, 0);
}

fn sizeOfDir(io: Io, dir: Io.Dir, depth: u16) u64 {
    if (depth > 32) return 0;
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .directory) {
            var sub = dir.openDir(io, e.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
            defer sub.close(io);
            total += sizeOfDir(io, sub, depth + 1);
            continue;
        }
        const st = dir.statFile(io, e.name, .{ .follow_symlinks = false }) catch continue;
        total += st.size;
    }
    return total;
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
// Sessao viva
// ---------------------------------------------------------------------------

/// Se o PID ainda existe. A poda usa isto para nao apagar a copia temporaria de
/// uma sessao que esta no meio de um `:w`.
pub fn processAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    return true;
}
