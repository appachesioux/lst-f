//! Nucleo puro: transforma a lista de origem e o buffer editado em um plano de
//! operacoes. Nao toca no filesystem; tudo aqui e testavel em memoria.
//!
//! O casamento entre origem e destino e feito **pelo ID**, nunca pela posicao
//! da linha. Linha apagada (ID some do buffer) significa remocao.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { dir, file, symlink, hardlink, other };

/// Uma entrada enviada ao editor. `path` e relativo ao diretorio-base da operacao.
pub const Original = struct {
    id: u32,
    path: []const u8,
    kind: Kind,
    /// Colunas somente de apresentacao, antes do separador e do caminho
    /// editavel. O plano nunca depende delas.
    display: []const u8 = "",
};

/// Uma linha lida de volta do buffer editado.
pub const Edit = struct {
    id: u32,
    path: []const u8,
    line: u32,
};

/// Uma linha do buffer que nao comeca por ID: pedido de criacao. Barra no fim
/// pede diretorio; qualquer pai que falte entra em `Plan.mkdirs`. `target` e o
/// destino de um symlink ou hardlink.
pub const Create = struct {
    /// Linha no buffer, para o relatorio de problemas.
    line: u32 = 0,
    path: []const u8,
    target: ?[]const u8 = null,
    kind: Kind,
    /// Diretorio-pai derivado de outra criacao. Ja existir e o caso normal,
    /// nao um erro -- ao contrario do que a linha pediu explicitamente.
    implicit: bool = false,
};

/// Copia de uma entrada: o ID aparece duas vezes no buffer, uma na origem
/// (inalterada) e outra no destino. A origem continua existindo.
pub const Copy = struct {
    id: u32,
    from: []const u8,
    to: []const u8,
    kind: Kind,
};

pub const Problem = union(enum) {
    create_empty_path: struct { line: u32 },
    create_absolute: struct { line: u32, path: []const u8 },
    create_escapes_base: struct { line: u32, path: []const u8 },
    create_reserved: struct { line: u32, path: []const u8 },
    create_duplicate: struct { line: u32, path: []const u8 },
    create_occupied: struct { line: u32, path: []const u8 },
    create_over_removed: struct { line: u32, path: []const u8, id: u32 },
    create_under_touched: struct { line: u32, path: []const u8, id: u32 },
    create_exists: struct { line: u32, path: []const u8 },
    link_empty_target: struct { line: u32, path: []const u8 },
    copy_no_free_name: struct { id: u32, path: []const u8 },
    copy_under_touched: struct { id: u32, path: []const u8 },
    id_without_path: struct { line: u32 },
    unknown_id: struct { line: u32, id: u32 },
    duplicate_id: struct { line: u32, id: u32 },
    empty_path: struct { id: u32 },
    absolute_path: struct { id: u32, path: []const u8 },
    escapes_base: struct { id: u32, path: []const u8 },
    reserved_name: struct { id: u32, path: []const u8 },
    duplicate_dest: struct { a: u32, b: u32, path: []const u8 },
    dest_occupied: struct { id: u32, path: []const u8 },
    dest_under_dest: struct { outer: u32, inner: u32 },
    parent_removed_child_moved: struct { parent: u32, child: u32 },
    parent_moved_child_touched: struct { parent: u32, child: u32 },
    unknown_directive: struct { line: u32, name: []const u8 },
    directive_needs_argument: struct { line: u32, name: []const u8 },
    multiple_directives: struct { line: u32 },

    pub fn describe(p: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (p) {
            .create_empty_path => |v| try w.print("linha {d}: nome vazio", .{v.line}),
            .create_absolute => |v| try w.print("linha {d}: caminho absoluto nao e aceito ({s})", .{ v.line, v.path }),
            .create_escapes_base => |v| try w.print("linha {d}: caminho sai do diretorio-base ({s})", .{ v.line, v.path }),
            .create_reserved => |v| try w.print("linha {d}: nome reservado pelo lst-f ({s})", .{ v.line, v.path }),
            .create_duplicate => |v| try w.print("linha {d}: duas linhas criam o mesmo caminho ({s})", .{ v.line, v.path }),
            .create_occupied => |v| try w.print("linha {d}: {s} ja pertence a uma entrada da selecao", .{ v.line, v.path }),
            .create_over_removed => |v| try w.print(
                "linha {d}: {s} pertence ao ID {d}, que esta sendo removido; remocoes acontecem por ultimo",
                .{ v.line, v.path, v.id },
            ),
            .create_under_touched => |v| try w.print(
                "linha {d}: {s} fica dentro do ID {d}, que esta sendo movido ou removido",
                .{ v.line, v.path, v.id },
            ),
            .create_exists => |v| try w.print("linha {d}: {s} ja existe no disco", .{ v.line, v.path }),
            .link_empty_target => |v| try w.print("linha {d}: link \"{s}\" sem destino (alvo)", .{ v.line, v.path }),
            .copy_no_free_name => |v| try w.print(
                "ID {d}: {s} colide e nao sobrou nome livre com sufixo (-01 a -99)",
                .{ v.id, v.path },
            ),
            .copy_under_touched => |v| try w.print(
                "ID {d}: {s} fica dentro de um diretorio que esta sendo movido ou removido",
                .{ v.id, v.path },
            ),
            .id_without_path => |v| try w.print("linha {d}: ID sem caminho", .{v.line}),
            .unknown_id => |v| try w.print("linha {d}: ID {d} nao pertence a selecao", .{ v.line, v.id }),
            .duplicate_id => |v| try w.print("linha {d}: ID {d} aparece mais de uma vez", .{ v.line, v.id }),
            .empty_path => |v| try w.print("ID {d}: caminho vazio", .{v.id}),
            .absolute_path => |v| try w.print("ID {d}: caminho absoluto nao e aceito ({s})", .{ v.id, v.path }),
            .escapes_base => |v| try w.print("ID {d}: caminho sai do diretorio-base ({s})", .{ v.id, v.path }),
            .reserved_name => |v| try w.print("ID {d}: nome reservado pelo lst-f ({s})", .{ v.id, v.path }),
            .duplicate_dest => |v| try w.print("IDs {d} e {d} apontam para o mesmo destino ({s})", .{ v.a, v.b, v.path }),
            .dest_occupied => |v| try w.print("ID {d}: destino ja ocupado por outra entrada da selecao ({s})", .{ v.id, v.path }),
            .dest_under_dest => |v| try w.print("ID {d} vira diretorio de ID {d}: destinos incompativeis", .{ v.outer, v.inner }),
            .parent_removed_child_moved => |v| try w.print(
                "ID {d} remove um diretorio que contem o ID {d}, que esta sendo renomeado",
                .{ v.parent, v.child },
            ),
            .parent_moved_child_touched => |v| try w.print(
                "ID {d} move um diretorio que contem o ID {d}, tambem alterado na mesma selecao",
                .{ v.parent, v.child },
            ),
            .unknown_directive => |v| try w.print("linha {d}: diretiva desconhecida \":{s}\"", .{ v.line, v.name }),
            .directive_needs_argument => |v| try w.print("linha {d}: \":{s}\" precisa de um argumento", .{ v.line, v.name }),
            .multiple_directives => |v| try w.print("linha {d}: so uma diretiva por vez", .{v.line}),
        }
    }
};

/// Movimento no nivel logico, para o diff. A execucao pode quebrar isso em
/// mais de um `rename` quando ha ciclo ou troca so de caixa.
pub const Move = struct {
    id: u32,
    from: []const u8,
    to: []const u8,
    kind: Kind,
};

pub const Rename = struct {
    from: []const u8,
    to: []const u8,
    /// Passo intermediario por nome temporario; nao aparece no diff.
    staging: bool = false,
};

pub const Remove = struct {
    id: u32,
    path: []const u8,
    kind: Kind,
};

pub const Plan = struct {
    /// Diretorios pai que o destino exige, do mais raso para o mais fundo.
    /// Podem ja existir; quem aplica filtra.
    mkdirs: []const []const u8,
    /// Ordem de execucao, ja resolvida (ciclos e troca de caixa incluidos).
    renames: []const Rename,
    /// Criacoes pedidas por linha sem ID. Acontecem depois das renomeacoes,
    /// para que um nome liberado no mesmo passo possa ser reocupado.
    creates: []const Create = &.{},
    /// Copias (ID duplicado no buffer). A origem fica; o destino e materializado
    /// depois das renomeacoes e criacoes.
    copies: []const Copy = &.{},
    /// Sempre por ultimo, exceto as antecipadas (`removes_before`) que liberam
    /// o nome de um destino de rename.
    removes: []const Remove,
    /// Quantas remocoes (prefixo de `removes`) acontecem antes das renomeacoes.
    removes_before: usize = 0,
    /// Visao logica, para o diff.
    moves: []const Move,
    unchanged: u32,

    pub fn isEmpty(p: Plan) bool {
        return p.renames.len == 0 and p.removes.len == 0 and p.mkdirs.len == 0 and
            p.creates.len == 0 and p.copies.len == 0;
    }
};

pub const Result = union(enum) {
    ok: Plan,
    invalid: []const Problem,
};

pub const Options = struct {
    /// Prefixo dos nomes temporarios usados para resolver ciclos. Fica sempre
    /// no mesmo diretorio da entrada, logo no mesmo filesystem.
    temp_prefix: []const u8 = ".lst-f-tmp-",
};

/// Prefixo da area de sessao; nenhum destino pode cair dentro dela.
pub const area_prefix = ".lst-f-";

/// Monta o plano. Toda a memoria sai de `arena`.
pub fn build(
    arena: Allocator,
    originals: []const Original,
    edits: []const Edit,
    creates: []const Create,
    options: Options,
) Allocator.Error!Result {
    var problems: std.ArrayList(Problem) = .empty;

    // --- 1. Casamento por ID -------------------------------------------------
    var by_id: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    for (originals, 0..) |o, i| try by_id.put(arena, o.id, i);

    const dests = try arena.alloc(?[]const u8, originals.len);
    @memset(dests, null);
    const dest_line = try arena.alloc(u32, originals.len);
    // Segundo caminho para o mesmo ID: a marca de uma copia. A origem fica,
    // o outro nome vira o destino da copia.
    const copy_dests = try arena.alloc(?[]const u8, originals.len);
    @memset(copy_dests, null);
    const copy_line = try arena.alloc(u32, originals.len);

    for (edits) |e| {
        const idx = by_id.get(e.id) orelse {
            try problems.append(arena, .{ .unknown_id = .{ .line = e.line, .id = e.id } });
            continue;
        };
        if (e.path.len == 0) {
            try problems.append(arena, .{ .id_without_path = .{ .line = e.line } });
            continue;
        }
        if (dests[idx] == null) {
            dests[idx] = e.path;
            dest_line[idx] = e.line;
        } else if (copy_dests[idx] == null) {
            copy_dests[idx] = e.path;
            copy_line[idx] = e.line;
        } else {
            try problems.append(arena, .{ .duplicate_id = .{ .line = e.line, .id = e.id } });
        }
    }
    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(arena) };

    // --- 1b. Classificacao das copias ----------------------------------------
    // ID duplicado: uma das linhas precisa casar com o caminho original (a
    // origem); a outra e o destino. As duas editadas e ambiguo.
    var copies: std.ArrayList(Copy) = .empty;
    for (originals, 0..) |o, i| {
        const cd = copy_dests[i] orelse continue;
        const first = dests[i].?; // sempre presente quando copy_dests != null
        // Diretorios ganham `/` apenas na representacao editavel do buffer.
        // A listagem interna guarda `dir`, enquanto o round-trip produz
        // `dir/`; ambos precisam identificar a linha que permaneceu na origem.
        const first_orig = matchesOriginalPath(o, first);
        const second_orig = matchesOriginalPath(o, cd);
        if (first_orig) {
            try copies.append(arena, .{ .id = o.id, .from = o.path, .to = cd, .kind = o.kind });
            dests[i] = o.path;
        } else if (second_orig) {
            try copies.append(arena, .{ .id = o.id, .from = o.path, .to = first, .kind = o.kind });
            dests[i] = o.path;
        } else {
            try problems.append(arena, .{ .duplicate_id = .{ .line = copy_line[i], .id = o.id } });
        }
    }
    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(arena) };

    // --- 2. Validacao lexical dos destinos -----------------------------------
    for (originals, 0..) |o, i| {
        const raw = dests[i] orelse continue;
        if (raw[0] == '/') {
            try problems.append(arena, .{ .absolute_path = .{ .id = o.id, .path = raw } });
            continue;
        }
        const norm = normalize(arena, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Escapes => {
                try problems.append(arena, .{ .escapes_base = .{ .id = o.id, .path = raw } });
                continue;
            },
            error.Empty => {
                try problems.append(arena, .{ .empty_path = .{ .id = o.id } });
                continue;
            },
        };
        if (isReserved(norm)) {
            try problems.append(arena, .{ .reserved_name = .{ .id = o.id, .path = raw } });
            continue;
        }
        dests[i] = norm;
    }

    // Mesmas regras lexicais para as linhas novas.
    const create_paths = try arena.alloc(?[]const u8, creates.len);
    @memset(create_paths, null);
    for (creates, 0..) |c, i| {
        if (c.kind == .symlink or c.kind == .hardlink) {
            if (c.target == null or c.target.?.len == 0) {
                try problems.append(arena, .{ .link_empty_target = .{ .line = c.line, .path = c.path } });
                continue;
            }
        }
        if (c.path.len > 0 and c.path[0] == '/') {
            try problems.append(arena, .{ .create_absolute = .{ .line = c.line, .path = c.path } });
            continue;
        }
        const norm = normalize(arena, c.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Escapes => {
                try problems.append(arena, .{ .create_escapes_base = .{ .line = c.line, .path = c.path } });
                continue;
            },
            error.Empty => {
                try problems.append(arena, .{ .create_empty_path = .{ .line = c.line } });
                continue;
            },
        };
        if (isReserved(norm)) {
            try problems.append(arena, .{ .create_reserved = .{ .line = c.line, .path = c.path } });
            continue;
        }
        create_paths[i] = norm;
    }
    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(arena) };

    // Mesmas regras lexicais para os destinos de copia.
    for (copies.items) |*c| {
        const raw = c.to;
        if (raw[0] == '/') {
            try problems.append(arena, .{ .absolute_path = .{ .id = c.id, .path = raw } });
            continue;
        }
        const norm = normalize(arena, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Escapes => {
                try problems.append(arena, .{ .escapes_base = .{ .id = c.id, .path = raw } });
                continue;
            },
            error.Empty => {
                try problems.append(arena, .{ .empty_path = .{ .id = c.id } });
                continue;
            },
        };
        if (isReserved(norm)) {
            try problems.append(arena, .{ .reserved_name = .{ .id = c.id, .path = raw } });
            continue;
        }
        c.to = norm;
    }
    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(arena) };

    // --- 3. Colisoes entre destinos ------------------------------------------
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    for (originals, 0..) |o, i| {
        const d = dests[i] orelse continue;
        const gop = try seen.getOrPut(arena, d);
        if (gop.found_existing) {
            try problems.append(arena, .{ .duplicate_dest = .{ .a = gop.value_ptr.*, .b = o.id, .path = d } });
            continue;
        }
        gop.value_ptr.* = o.id;
    }

    // Destino que engole outro destino: "a" e "a/b" nao podem coexistir.
    for (originals, 0..) |outer, i| {
        const a = dests[i] orelse continue;
        for (originals, 0..) |inner, j| {
            if (i == j) continue;
            const b = dests[j] orelse continue;
            if (isUnder(a, b)) {
                try problems.append(arena, .{ .dest_under_dest = .{ .outer = outer.id, .inner = inner.id } });
            }
        }
    }

    // Destino ocupado por entrada da selecao que fica onde esta.
    for (originals, 0..) |o, i| {
        const d = dests[i] orelse continue;
        if (std.mem.eql(u8, d, o.path)) continue;
        for (originals, 0..) |other, j| {
            if (i == j) continue;
            if (!std.mem.eql(u8, other.path, d)) continue;
            if (dests[j]) |od| {
                if (std.mem.eql(u8, od, other.path)) {
                    try problems.append(arena, .{ .dest_occupied = .{ .id = o.id, .path = d } });
                }
            }
            // Entrada removida (sem destino) libera o nome; a ordenacao em 8
            // garante que a remocao aconteca antes do rename que a ocupa.
        }
    }

    // Um caminho novo nao pode disputar lugar com destino de rename, com
    // entrada que fica onde esta, nem com outra linha nova.
    var create_seen: std.StringHashMapUnmanaged(void) = .empty;
    for (creates, 0..) |c, i| {
        const path = create_paths[i] orelse continue;
        if (seen.get(path) != null) {
            try problems.append(arena, .{ .create_occupied = .{ .line = c.line, .path = path } });
            continue;
        }
        if ((try create_seen.getOrPut(arena, path)).found_existing) {
            try problems.append(arena, .{ .create_duplicate = .{ .line = c.line, .path = path } });
        }
    }

    // Remocoes acontecem por ultimo, entao criar sobre o caminho de uma entrada
    // removida sairia trocado. Criar dentro de um diretorio que sai do lugar
    // levaria o arquivo novo junto, em silencio.
    for (creates, 0..) |c, i| {
        const path = create_paths[i] orelse continue;
        for (originals, 0..) |o, j| {
            const d = dests[j];
            if (std.mem.eql(u8, o.path, path)) {
                if (d == null) {
                    try problems.append(arena, .{
                        .create_over_removed = .{ .line = c.line, .path = path, .id = o.id },
                    });
                }
                continue;
            }
            if (!isUnder(o.path, path)) continue;
            const stays = d != null and std.mem.eql(u8, d.?, o.path);
            if (!stays) {
                try problems.append(arena, .{
                    .create_under_touched = .{ .line = c.line, .path = path, .id = o.id },
                });
            }
        }
    }
    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(arena) };

    // --- 4. Pai e filho na mesma selecao -------------------------------------
    const absorbed = try arena.alloc(bool, originals.len);
    @memset(absorbed, false);

    for (originals, 0..) |parent, i| {
        if (parent.kind != .dir) continue;
        const p_dest = dests[i];
        for (originals, 0..) |child, j| {
            if (i == j) continue;
            if (!isUnder(parent.path, child.path)) continue;
            const c_dest = dests[j];
            if (p_dest == null) {
                if (c_dest == null) {
                    // Pai e filho removidos: redundancia, o pai leva o filho junto.
                    absorbed[j] = true;
                } else if (!std.mem.eql(u8, c_dest.?, child.path)) {
                    try problems.append(arena, .{
                        .parent_removed_child_moved = .{ .parent = parent.id, .child = child.id },
                    });
                }
                // Pai removido e filho inalterado: o filho vai junto, sem operacao.
            } else if (!std.mem.eql(u8, p_dest.?, parent.path)) {
                // Pai muda de lugar: qualquer alteracao no filho e ambigua.
                const child_touched = c_dest == null or !std.mem.eql(u8, c_dest.?, child.path);
                if (child_touched) {
                    try problems.append(arena, .{
                        .parent_moved_child_touched = .{ .parent = parent.id, .child = child.id },
                    });
                }
            }
        }
    }
    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(arena) };

    // --- 5. Particao em manter / mover / remover -----------------------------
    var moves: std.ArrayList(Move) = .empty;
    var removes: std.ArrayList(Remove) = .empty;
    var unchanged: u32 = 0;

    for (originals, 0..) |o, i| {
        if (absorbed[i]) continue;
        if (dests[i]) |d| {
            if (std.mem.eql(u8, d, o.path)) {
                unchanged += 1;
            } else {
                try moves.append(arena, .{ .id = o.id, .from = o.path, .to = d, .kind = o.kind });
            }
        } else {
            try removes.append(arena, .{ .id = o.id, .path = o.path, .kind = o.kind });
        }
    }

    // Copiar para dentro de um diretorio que sai do lugar levaria o arquivo
    // junto (removido) ou o deixaria para tras (movido). Mesmo argumento da
    // criacao.
    for (copies.items) |c| {
        for (originals, 0..) |o, j| {
            if (!isUnder(o.path, c.to)) continue;
            const d = dests[j];
            const stays = d != null and std.mem.eql(u8, d.?, o.path);
            if (!stays) {
                try problems.append(arena, .{ .copy_under_touched = .{ .id = c.id, .path = c.to } });
            }
        }
    }
    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(arena) };

    // --- 6. Diretorios pai exigidos pelos destinos ---------------------------
    var mkdirs: std.ArrayList([]const u8) = .empty;
    var mkdir_seen: std.StringHashMapUnmanaged(void) = .empty;
    for (moves.items) |m| {
        var end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, m.to, end, '/')) |slash| {
            end = slash + 1;
            const ancestor = m.to[0..slash];
            if ((try mkdir_seen.getOrPut(arena, ancestor)).found_existing) continue;
            try mkdirs.append(arena, ancestor);
        }
    }
    for (copies.items) |c| {
        var end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, c.to, end, '/')) |slash| {
            end = slash + 1;
            const ancestor = c.to[0..slash];
            if ((try mkdir_seen.getOrPut(arena, ancestor)).found_existing) continue;
            try mkdirs.append(arena, ancestor);
        }
    }

    // --- 7. Criacoes, com os pais que faltam na frente -----------------------
    // Tudo isso acontece depois das renomeacoes, entao os pais nao podem ir
    // para `mkdirs` (fase anterior): um diretorio novo pode depender de um nome
    // que so fica livre quando a renomeacao passar.
    var new_entries: std.ArrayList(Create) = .empty;
    var new_seen: std.StringHashMapUnmanaged(void) = .empty;
    for (creates, 0..) |c, i| {
        const path = create_paths[i] orelse continue;
        var end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, end, '/')) |slash| {
            end = slash + 1;
            const ancestor = path[0..slash];
            if ((try new_seen.getOrPut(arena, ancestor)).found_existing) continue;
            try new_entries.append(arena, .{
                .line = c.line,
                .path = ancestor,
                .kind = .dir,
                .implicit = true,
            });
        }
        // Diretorio que ja entrou como pai implicito nao entra duas vezes.
        if ((try new_seen.getOrPut(arena, path)).found_existing) continue;
        try new_entries.append(arena, .{
            .line = c.line,
            .path = path,
            .target = c.target,
            .kind = c.kind,
        });
    }

    // --- 8. Ordem de execucao: ciclos, troca so de caixa e remocao antecipada -
    const renames = try order(arena, moves.items, options);

    // Remocao cujo caminho e o destino de um rename tem que sair antes dele:
    // o destino precisa estar livre na hora do rename. E o que o oil.nvim faz
    // (o DELETE de um caminho roda antes do MOVE que o ocupa). As demais
    // continuam por ultimo, como sempre.
    var removes_early: std.ArrayList(Remove) = .empty;
    var removes_late: std.ArrayList(Remove) = .empty;
    for (removes.items) |rm| {
        var targeted = false;
        for (moves.items) |m| {
            if (std.mem.eql(u8, m.to, rm.path)) {
                targeted = true;
                break;
            }
        }
        if (targeted) try removes_early.append(arena, rm) else try removes_late.append(arena, rm);
    }
    const removes_before = removes_early.items.len;
    const removes_ordered = try arena.alloc(Remove, removes.items.len);
    @memcpy(removes_ordered[0..removes_before], removes_early.items);
    @memcpy(removes_ordered[removes_before..], removes_late.items);

    return .{ .ok = .{
        .mkdirs = try mkdirs.toOwnedSlice(arena),
        .renames = renames,
        .creates = try new_entries.toOwnedSlice(arena),
        .copies = try copies.toOwnedSlice(arena),
        .removes = removes_ordered,
        .removes_before = removes_before,
        .moves = try moves.toOwnedSlice(arena),
        .unchanged = unchanged,
    } };
}

/// Sequencia os movimentos para que nenhum `rename` sobrescreva um caminho que
/// ainda nao foi liberado. Ciclos e trocas so de caixa passam por temporario.
fn order(arena: Allocator, moves: []const Move, options: Options) Allocator.Error![]const Rename {
    var out: std.ArrayList(Rename) = .empty;
    const n = moves.len;
    if (n == 0) return out.toOwnedSlice(arena);

    // Caminho onde cada movimento esta agora (muda ao passar por temporario).
    const current = try arena.alloc([]const u8, n);
    const done = try arena.alloc(bool, n);
    for (moves, 0..) |m, i| {
        current[i] = m.from;
        done[i] = false;
    }

    // Ocupacao: caminho -> movimento que ainda esta sentado nele.
    var occupied: std.StringHashMapUnmanaged(usize) = .empty;
    for (moves, 0..) |m, i| try occupied.put(arena, m.from, i);

    var temp_n: u32 = 0;

    // Troca so de caixa nao pode ir direto: em filesystem case-insensitive o
    // destino "ja existe". Sempre pelo temporario, sem tentar detectar o fs.
    for (moves, 0..) |m, i| {
        if (!caseOnlyDiff(m.from, m.to)) continue;
        const tmp = try tempPath(arena, m.from, options.temp_prefix, temp_n);
        temp_n += 1;
        try out.append(arena, .{ .from = current[i], .to = tmp, .staging = true });
        _ = occupied.remove(current[i]);
        current[i] = tmp;
    }

    var remaining = n;
    while (remaining > 0) {
        var progress = false;
        for (moves, 0..) |m, i| {
            if (done[i]) continue;
            if (occupied.get(m.to)) |_| continue; // destino ainda ocupado
            try out.append(arena, .{ .from = current[i], .to = m.to });
            _ = occupied.remove(current[i]);
            done[i] = true;
            remaining -= 1;
            progress = true;
        }
        if (progress) continue;

        // Sobrou so ciclo: tira um do caminho por um temporario.
        for (moves, 0..) |m, i| {
            if (done[i]) continue;
            const tmp = try tempPath(arena, m.from, options.temp_prefix, temp_n);
            temp_n += 1;
            try out.append(arena, .{ .from = current[i], .to = tmp, .staging = true });
            _ = occupied.remove(current[i]);
            current[i] = tmp;
            break;
        }
    }

    return out.toOwnedSlice(arena);
}

fn matchesOriginalPath(original: Original, edited: []const u8) bool {
    if (std.mem.eql(u8, edited, original.path)) return true;
    return original.kind == .dir and
        edited.len == original.path.len + 1 and
        edited[edited.len - 1] == '/' and
        std.mem.eql(u8, edited[0..original.path.len], original.path);
}

fn tempPath(arena: Allocator, near: []const u8, prefix: []const u8, n: u32) Allocator.Error![]const u8 {
    const dir = std.fs.path.dirname(near);
    return if (dir) |d|
        std.fmt.allocPrint(arena, "{s}/{s}{d}", .{ d, prefix, n })
    else
        std.fmt.allocPrint(arena, "{s}{d}", .{ prefix, n });
}

fn caseOnlyDiff(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (std.mem.eql(u8, a, b)) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// `child` esta estritamente dentro de `parent`?
pub fn isUnder(parent: []const u8, child: []const u8) bool {
    if (child.len <= parent.len + 1) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child[parent.len] == '/';
}

fn isReserved(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.startsWith(u8, comp, area_prefix)) return true;
    }
    return false;
}

/// Nome para a n-esima tentativa de evitar colisao: insere `-NN` (dois digitos,
/// zero a esquerda) antes da extensao. Diretorios nao partem a extensao.
/// `report.pdf` -> `report-01.pdf`; `dir` -> `dir-01`.
pub fn suffixed(arena: Allocator, dest: []const u8, n: u32, is_dir: bool) Allocator.Error![]const u8 {
    const base = std.fs.path.basename(dest);
    var stem = base;
    var ext: []const u8 = "";
    if (!is_dir) {
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
            if (dot > 0) {
                stem = base[0..dot];
                ext = base[dot..];
            }
        }
    }
    const name = try std.fmt.allocPrint(arena, "{s}-{d:0>2}{s}", .{ stem, n, ext });
    const dir = std.fs.path.dirname(dest);
    return if (dir) |d| std.fmt.allocPrint(arena, "{s}/{s}", .{ d, name }) else name;
}

pub const NormalizeError = error{ Escapes, Empty, OutOfMemory };

/// Normalizacao puramente lexical, antes de qualquer resolucao no filesystem:
/// remove `.` e componentes vazios, aplica `..` e recusa sair do base.
pub fn normalize(arena: Allocator, path: []const u8) NormalizeError![]const u8 {
    var comps: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (comps.items.len == 0) return error.Escapes;
            _ = comps.pop();
            continue;
        }
        try comps.append(arena, comp);
    }
    if (comps.items.len == 0) return error.Empty;
    return std.mem.join(arena, "/", comps.items);
}

// ---------------------------------------------------------------------------
// Parsing do buffer editado
// ---------------------------------------------------------------------------

/// Diretiva de navegacao: a linha comeca por `:`, como um comando ex. Linha de
/// entrada sempre comeca por `/` seguido de digitos, entao nao ha ambiguidade
/// com nome de arquivo nem com diretiva.
pub const Directive = union(enum) {
    cd: []const u8,
    find: []const u8,
    open: []const u8,
    shell: ?[]const u8,
    hidden: ?bool,
    /// Inserida pelo helper antes de `:w`, para que salvar sem alteracao
    /// mantenha a sessao aberta e apenas atualize a listagem.
    refresh,
    undo,
    quit,
    /// Andam sobre os diretorios ja visitados na sessao.
    back,
    forward,
};

pub const Document = struct {
    edits: []const Edit,
    /// Linhas sem ID: pedidos de criacao, na ordem em que aparecem.
    creates: []const Create = &.{},
    /// No maximo uma por rodada: duas seriam duas telas ao mesmo tempo.
    directive: ?Directive = null,
};

pub const ParseResult = union(enum) {
    ok: Document,
    invalid: []const Problem,
};

/// O cabecalho e reconhecido por identidade, nunca por semelhanca: o buffer e
/// texto livre e o usuario pode apagar, mover, ordenar ou reescrever essas
/// linhas. Adivinhar custava dos dois lados -- `relatorio v2.txt` era engolido
/// como se fosse cabecalho, e um `:sort` mandava linha de cabecalho para o meio
/// das entradas, onde virava pedido de criacao.
fn isHeaderLine(line: []const u8, header: []const []const u8) bool {
    for (header) |h| {
        if (std.mem.eql(u8, h, line)) return true;
    }
    return false;
}

fn extractPath(body: []const u8) []const u8 {
    // Formato com grade de colunas (5 colunas) e icone antes do nome: `d │ ... │ 2026-08-25 23:53 │   caminho`
    if (body.len >= 58 and std.mem.eql(u8, body[1..4], " │ ") and std.mem.eql(u8, body[55..58], " │ ")) {
        const after_sep = body[58..];
        if (after_sep.len > 0 and after_sep[0] >= 0x80) {
            const cp_len = std.unicode.utf8ByteSequenceLength(after_sep[0]) catch 0;
            if (cp_len > 0 and after_sep.len >= cp_len) {
                const rest = after_sep[cp_len..];
                if (std.mem.startsWith(u8, rest, "  ")) return rest[2..];
                if (std.mem.startsWith(u8, rest, " ")) return rest[1..];
                return rest;
            }
        }
        if (std.mem.startsWith(u8, after_sep, "  ")) return after_sep[2..];
        if (std.mem.startsWith(u8, after_sep, " ")) return after_sep[1..];
        return after_sep;
    }
    // Formato com grade de colunas e icone com divisor extra: `d │ ... │   │  caminho`
    if (body.len >= 76 and std.mem.eql(u8, body[1..4], " │ ") and std.mem.eql(u8, body[71..76], "  │")) {
        const rest = body[76..];
        if (std.mem.startsWith(u8, rest, "  ")) return rest[2..];
        if (std.mem.startsWith(u8, rest, " ")) return rest[1..];
        return rest;
    }
    // Formato com grade de colunas antiga: `d │ ... │  caminho`
    if (body.len >= 67 and std.mem.eql(u8, body[1..4], " │ ") and std.mem.eql(u8, body[63..67], " │")) {
        const rest = body[67..];
        if (std.mem.startsWith(u8, rest, "  ")) return rest[2..];
        if (std.mem.startsWith(u8, rest, " ")) return rest[1..];
        return rest;
    }
    // Formato com grade de colunas antiga (com borda externa `│ d │ ...`):
    if (std.mem.startsWith(u8, body, "│ ") and body.len >= 58 and std.mem.eql(u8, body[54..58], " │")) {
        const rest = body[58..];
        if (std.mem.startsWith(u8, rest, "  ")) return rest[2..];
        if (std.mem.startsWith(u8, rest, " ")) return rest[1..];
        return rest;
    }
    // Formato com divisor `  │  ` ou ` │ `
    if (std.mem.lastIndexOf(u8, body, " │ ")) |sep| {
        const after_sep = body[sep + " │ ".len ..];
        if (after_sep.len > 0 and after_sep[0] >= 0x80) {
            const cp_len = std.unicode.utf8ByteSequenceLength(after_sep[0]) catch 0;
            if (cp_len > 0 and after_sep.len >= cp_len) {
                const rest = after_sep[cp_len..];
                if (std.mem.startsWith(u8, rest, "  ")) return rest[2..];
                if (std.mem.startsWith(u8, rest, " ")) return rest[1..];
                return rest;
            }
        }
        if (std.mem.startsWith(u8, after_sep, "  ")) return after_sep[2..];
        if (std.mem.startsWith(u8, after_sep, " ")) return after_sep[1..];
        return after_sep;
    }
    if (std.mem.indexOf(u8, body, "  │  ")) |sep| {
        return body[sep + "  │  ".len ..];
    }
    return body;
}

/// Linha do corpo que nao comeca por ID: pedido de criacao. O espaco a esquerda
/// e alinhamento com a coluna NAME, nunca parte do nome.
/// `nome -> alvo` cria symlink; `nome => alvo` cria hardlink.
fn newEntry(line: []const u8, line_no: u32) ?Create {
    const body = std.mem.trimStart(u8, extractPath(std.mem.trimStart(u8, line, " \t")), " \t");
    if (body.len == 0) return null;

    if (std.mem.indexOf(u8, body, " -> ")) |sep| {
        const link_name = std.mem.trim(u8, body[0..sep], " \t");
        const target = std.mem.trim(u8, body[sep + 4 ..], " \t");
        if (link_name.len > 0) {
            return .{
                .line = line_no,
                .path = link_name,
                .target = target,
                .kind = .symlink,
            };
        }
    }

    if (std.mem.indexOf(u8, body, " => ")) |sep| {
        const link_name = std.mem.trim(u8, body[0..sep], " \t");
        const target = std.mem.trim(u8, body[sep + 4 ..], " \t");
        if (link_name.len > 0) {
            return .{
                .line = line_no,
                .path = link_name,
                .target = target,
                .kind = .hardlink,
            };
        }
    }

    return .{
        .line = line_no,
        .path = body,
        .target = null,
        .kind = if (body[body.len - 1] == '/') .dir else .file,
    };
}

/// Le o buffer que voltou do editor. O cabecalho ocupa o inicio do buffer
/// e o conteudo util com as entradas fica logo abaixo. Cada linha util e
/// `/<digitos><espacos><caminho>`; linha sem ID no corpo pede criacao.
/// Linhas em branco e linhas iniciadas por `#` sao ignoradas.
/// O caminho vai ate o fim da linha, sem trim: espaco no fim de nome e legitimo.
pub fn parseBuffer(
    arena: Allocator,
    text: []const u8,
    /// As linhas que `writeBuffer` colocou no topo, para reconhece-las onde
    /// quer que tenham parado.
    header: []const []const u8,
) Allocator.Error!ParseResult {
    var edits: std.ArrayList(Edit) = .empty;
    var creates: std.ArrayList(Create) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    var directive: ?Directive = null;

    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (isHeaderLine(line, header)) continue;

        if (line[0] == ':') {
            const body = std.mem.trim(u8, line[1..], " \t");
            const split = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
            const name = body[0..split];
            const argument = std.mem.trim(u8, body[split..], " \t");

            if (std.mem.eql(u8, name, "ln") or std.mem.eql(u8, name, "link") or std.mem.eql(u8, name, "symlink")) {
                if (argument.len == 0) {
                    try problems.append(arena, .{ .directive_needs_argument = .{ .line = line_no, .name = try arena.dupe(u8, name) } });
                    continue;
                }
                const split_arg = std.mem.indexOfAny(u8, argument, " \t") orelse argument.len;
                const target = argument[0..split_arg];
                const raw_name = std.mem.trim(u8, argument[split_arg..], " \t");
                const link_name = if (raw_name.len > 0) raw_name else std.fs.path.basename(target);
                try creates.append(arena, .{
                    .line = line_no,
                    .path = link_name,
                    .target = target,
                    .kind = .symlink,
                });
                continue;
            } else if (std.mem.eql(u8, name, "hardlink")) {
                if (argument.len == 0) {
                    try problems.append(arena, .{ .directive_needs_argument = .{ .line = line_no, .name = "hardlink" } });
                    continue;
                }
                const split_arg = std.mem.indexOfAny(u8, argument, " \t") orelse argument.len;
                const target = argument[0..split_arg];
                const raw_name = std.mem.trim(u8, argument[split_arg..], " \t");
                const link_name = if (raw_name.len > 0) raw_name else std.fs.path.basename(target);
                try creates.append(arena, .{
                    .line = line_no,
                    .path = link_name,
                    .target = target,
                    .kind = .hardlink,
                });
                continue;
            }

            if (directive != null) {
                try problems.append(arena, .{ .multiple_directives = .{ .line = line_no } });
                continue;
            }

            if (std.mem.eql(u8, name, "cd")) {
                directive = .{ .cd = if (argument.len == 0) "~" else argument };
            } else if (std.mem.eql(u8, name, "home") or std.mem.eql(u8, name, "~")) {
                directive = .{ .cd = "~" };
            } else if (std.mem.eql(u8, name, "open") or std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "e")) {
                if (argument.len == 0) {
                    try problems.append(arena, .{ .directive_needs_argument = .{ .line = line_no, .name = "open" } });
                    continue;
                }
                directive = .{ .open = argument };
            } else if (std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "shell") or std.mem.eql(u8, name, "terminal") or std.mem.eql(u8, name, "term")) {
                directive = .{ .shell = if (argument.len == 0) null else argument };
            } else if (std.mem.eql(u8, name, "find")) {
                directive = .{ .find = argument };
            } else if (std.mem.eql(u8, name, "hidden") or std.mem.eql(u8, name, "hide") or std.mem.eql(u8, name, "dotfiles")) {
                if (argument.len == 0 or std.mem.eql(u8, argument, "toggle")) {
                    directive = .{ .hidden = null };
                } else if (std.mem.eql(u8, argument, "on") or std.mem.eql(u8, argument, "1") or std.mem.eql(u8, argument, "true") or std.mem.eql(u8, argument, "show")) {
                    directive = .{ .hidden = true };
                } else if (std.mem.eql(u8, argument, "off") or std.mem.eql(u8, argument, "0") or std.mem.eql(u8, argument, "false")) {
                    directive = .{ .hidden = false };
                } else {
                    try problems.append(arena, .{
                        .unknown_directive = .{ .line = line_no, .name = try arena.dupe(u8, name) },
                    });
                }
            } else if (std.mem.eql(u8, name, "back")) {
                directive = .back;
            } else if (std.mem.eql(u8, name, "forward")) {
                directive = .forward;
            } else if (std.mem.eql(u8, name, "refresh")) {
                directive = .refresh;
            } else if (std.mem.eql(u8, name, "undo")) {
                directive = .undo;
            } else if (std.mem.eql(u8, name, "quit") or std.mem.eql(u8, name, "q")) {
                directive = .quit;
            } else {
                try problems.append(arena, .{
                    .unknown_directive = .{ .line = line_no, .name = try arena.dupe(u8, name) },
                });
            }
            continue;
        }

        // `/` e o unico byte que um nome de arquivo nao pode conter, entao
        // `/<digitos><espaco>` nunca colide com um nome que o usuario digite.
        var i: usize = 1;
        if (line[0] != '/') {
            if (newEntry(line, line_no)) |c| try creates.append(arena, c);
            continue;
        }
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == 1 or (i < line.len and line[i] != ' ' and line[i] != '\t')) {
            if (newEntry(line, line_no)) |c| try creates.append(arena, c);
            continue;
        }

        const id = std.fmt.parseInt(u32, line[1..i], 10) catch {
            if (newEntry(line, line_no)) |c| try creates.append(arena, c);
            continue;
        };

        var j = i;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        if (j == i and j < line.len) {
            // digitos colados no caminho: nao e uma linha nossa

            if (newEntry(line, line_no)) |c| try creates.append(arena, c);
            continue;
        }

        const body = line[j..];
        const path = extractPath(body);
        try edits.append(arena, .{ .id = id, .path = path, .line = line_no });
    }

    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(arena) };
    return .{ .ok = .{
        .edits = try edits.toOwnedSlice(arena),
        .creates = try creates.toOwnedSlice(arena),
        .directive = directive,
    } };
}

/// Cabecalho do buffer. E a barra de localizacao desta interface: o buffer do
/// editor **e** a tela, entao o que um gerenciador de arquivos poria numa barra
/// de titulo mora aqui no topo do arquivo.
pub const BufferHeader = struct {
    /// Origem do conteudo, quando nao e a listagem do diretorio.
    scope: ?[]const u8 = null,
    /// Nomes que nao sao UTF-8 valido: aparecem, mas fora da edicao.
    unlistable: []const []const u8 = &.{},
    notes: []const []const u8 = &.{},
};

/// As linhas que vao antes das entradas -- escopo do `:find` e avisos. Escrita
/// e leitura saem daqui, para que o parser reconheca o cabecalho pelo texto
/// exato que produziu.
///
/// Os titulos das colunas nao estao aqui: o helper os desenha na barra de topo
/// do editor. Linha de tela nao rola com a lista, nao pode ser apagada e se
/// redesenha sozinha quando o terminal muda de tamanho.
pub fn headerLines(arena: Allocator, header: BufferHeader) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (header.scope) |scope| try out.append(arena, scope);
    for (header.notes) |note| {
        try out.append(arena, try std.fmt.allocPrint(arena, "aviso: {s}", .{note}));
    }
    for (header.unlistable) |name| {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(arena, "fora da edicao, nome nao e UTF-8 valido: ");
        for (name) |c| {
            if (c >= 0x20 and c < 0x7f) {
                try line.append(arena, c);
            } else {
                try line.appendSlice(arena, try std.fmt.allocPrint(arena, "\\x{x:0>2}", .{c}));
            }
        }
        try out.append(arena, line.items);
    }
    return out.toOwnedSlice(arena);
}

/// Escreve o buffer que vai para o editor.
pub fn writeBuffer(
    arena: Allocator,
    w: *std.Io.Writer,
    header: BufferHeader,
    originals: []const Original,
) !void {
    for (try headerLines(arena, header)) |line| try w.print("{s}\n", .{line});
    for (originals) |o| {
        const slash: []const u8 = if (o.kind == .dir and !std.mem.endsWith(u8, o.path, "/")) "/" else "";
        if (o.display.len > 0) {
            try w.print("/{d:0>4}  {s}  {s}{s}\n", .{ o.id, o.display, o.path, slash });
        } else {
            try w.print("/{d:0>4}  {s}{s}\n", .{ o.id, o.path, slash });
        }
    }
}
