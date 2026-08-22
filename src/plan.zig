//! Nucleo puro: transforma a lista de origem e o buffer editado em um plano de
//! operacoes. Nao toca no filesystem; tudo aqui e testavel em memoria.
//!
//! O casamento entre origem e destino e feito **pelo ID**, nunca pela posicao
//! da linha. Linha apagada (ID some do buffer) significa remocao.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { dir, file, other };

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

pub const Problem = union(enum) {
    line_without_id: u32,
    id_without_path: struct { line: u32 },
    unknown_id: struct { line: u32, id: u32 },
    duplicate_id: struct { line: u32, id: u32 },
    empty_path: struct { id: u32 },
    absolute_path: struct { id: u32, path: []const u8 },
    escapes_base: struct { id: u32, path: []const u8 },
    reserved_name: struct { id: u32, path: []const u8 },
    duplicate_dest: struct { a: u32, b: u32, path: []const u8 },
    dest_occupied: struct { id: u32, path: []const u8 },
    dest_occupied_by_removed: struct { id: u32, other: u32, path: []const u8 },
    dest_under_dest: struct { outer: u32, inner: u32 },
    parent_removed_child_moved: struct { parent: u32, child: u32 },
    parent_moved_child_touched: struct { parent: u32, child: u32 },
    unknown_directive: struct { line: u32, name: []const u8 },
    directive_needs_argument: struct { line: u32, name: []const u8 },
    multiple_directives: struct { line: u32 },

    pub fn describe(p: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (p) {
            .line_without_id => |l| try w.print("linha {d}: nao comeca com um ID", .{l}),
            .id_without_path => |v| try w.print("linha {d}: ID sem caminho", .{v.line}),
            .unknown_id => |v| try w.print("linha {d}: ID {d} nao pertence a selecao", .{ v.line, v.id }),
            .duplicate_id => |v| try w.print("linha {d}: ID {d} aparece mais de uma vez", .{ v.line, v.id }),
            .empty_path => |v| try w.print("ID {d}: caminho vazio", .{v.id}),
            .absolute_path => |v| try w.print("ID {d}: caminho absoluto nao e aceito ({s})", .{ v.id, v.path }),
            .escapes_base => |v| try w.print("ID {d}: caminho sai do diretorio-base ({s})", .{ v.id, v.path }),
            .reserved_name => |v| try w.print("ID {d}: nome reservado pelo lst-f ({s})", .{ v.id, v.path }),
            .duplicate_dest => |v| try w.print("IDs {d} e {d} apontam para o mesmo destino ({s})", .{ v.a, v.b, v.path }),
            .dest_occupied => |v| try w.print("ID {d}: destino ja ocupado por outra entrada da selecao ({s})", .{ v.id, v.path }),
            .dest_occupied_by_removed => |v| try w.print(
                "ID {d}: destino {s} pertence ao ID {d}, que esta sendo removido; remocoes acontecem por ultimo",
                .{ v.id, v.path, v.other },
            ),
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
    /// Sempre por ultimo.
    removes: []const Remove,
    /// Visao logica, para o diff.
    moves: []const Move,
    unchanged: u32,

    pub fn isEmpty(p: Plan) bool {
        return p.renames.len == 0 and p.removes.len == 0 and p.mkdirs.len == 0;
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
    options: Options,
) Allocator.Error!Result {
    var problems: std.ArrayList(Problem) = .empty;

    // --- 1. Casamento por ID -------------------------------------------------
    var by_id: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    for (originals, 0..) |o, i| try by_id.put(arena, o.id, i);

    const dests = try arena.alloc(?[]const u8, originals.len);
    @memset(dests, null);
    const dest_line = try arena.alloc(u32, originals.len);

    for (edits) |e| {
        const idx = by_id.get(e.id) orelse {
            try problems.append(arena, .{ .unknown_id = .{ .line = e.line, .id = e.id } });
            continue;
        };
        if (dests[idx] != null) {
            try problems.append(arena, .{ .duplicate_id = .{ .line = e.line, .id = e.id } });
            continue;
        }
        if (e.path.len == 0) {
            try problems.append(arena, .{ .id_without_path = .{ .line = e.line } });
            continue;
        }
        dests[idx] = e.path;
        dest_line[idx] = e.line;
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

    // Destino ocupado por entrada da selecao que nao sai do lugar.
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
            } else {
                try problems.append(arena, .{
                    .dest_occupied_by_removed = .{ .id = o.id, .other = other.id, .path = d },
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

    // --- 7. Ordem de execucao: ciclos e troca so de caixa --------------------
    const renames = try order(arena, moves.items, options);

    return .{ .ok = .{
        .mkdirs = try mkdirs.toOwnedSlice(arena),
        .renames = renames,
        .removes = try removes.toOwnedSlice(arena),
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
/// entrada sempre comeca por digito, entao nao ha ambiguidade com nome de arquivo.
pub const Directive = union(enum) {
    cd: []const u8,
    find: []const u8,
    open: []const u8,
    hidden: ?bool,
    /// Inserida pelo helper antes de `:w`, para que salvar sem alteracao
    /// mantenha a sessao aberta e apenas atualize a listagem.
    refresh,
    undo,
    quit,
};

pub const Document = struct {
    edits: []const Edit,
    /// No maximo uma por rodada: duas seriam duas telas ao mesmo tempo.
    directive: ?Directive = null,
};

pub const ParseResult = union(enum) {
    ok: Document,
    invalid: []const Problem,
};

fn isHeaderLine(line: []const u8) bool {
    if (line.len == 0) return true;
    if (line[0] == '#') return true;
    if (std.mem.indexOf(u8, line, " · ") != null) return true;
    if (std.mem.indexOf(u8, line, " v") != null) return true;
    if (std.mem.startsWith(u8, line, "lst-f")) return true;
    if (std.mem.startsWith(u8, line, "aviso:")) return true;
    if (std.mem.startsWith(u8, line, "fora da edicao")) return true;
    if (std.mem.startsWith(u8, line, "resultado de :find")) return true;
    if (std.mem.startsWith(u8, line, "T │") or std.mem.startsWith(u8, line, "T│") or std.mem.startsWith(u8, line, "ID  ")) return true;
    if (std.mem.startsWith(u8, line, "──┼") or std.mem.startsWith(u8, line, "--+") or std.mem.startsWith(u8, line, "──┬") or std.mem.startsWith(u8, line, "───")) return true;
    if (std.mem.startsWith(u8, line, "╭") or std.mem.startsWith(u8, line, "┌")) return true;
    if (std.mem.startsWith(u8, line, "│ T") or std.mem.startsWith(u8, line, "│  T")) return true;
    if (std.mem.startsWith(u8, line, "╰") or std.mem.startsWith(u8, line, "└")) return true;
    return false;
}

fn extractPath(body: []const u8) []const u8 {
    // Formato com grade de colunas: `d │ ... │  caminho`
    if (body.len >= 54 and std.mem.eql(u8, body[1..4], " │ ") and std.mem.eql(u8, body[50..54], " │")) {
        const rest = body[54..];
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
        const rest = body[sep + " │ ".len ..];
        if (std.mem.startsWith(u8, rest, " ")) return rest[1..];
        return rest;
    }
    if (std.mem.indexOf(u8, body, "  │  ")) |sep| {
        return body[sep + "  │  ".len ..];
    }
    return body;
}

/// Le o buffer que voltou do editor. O cabecalho ocupa o inicio do buffer
/// e o conteudo util com as entradas fica logo abaixo. Cada linha util e
/// `<digitos><espacos><caminho>`.
/// Linhas em branco e linhas iniciadas por `#` sao ignoradas.
/// O caminho vai ate o fim da linha, sem trim: espaco no fim de nome e legitimo.
pub fn parseBuffer(arena: Allocator, text: []const u8) Allocator.Error!ParseResult {
    var edits: std.ArrayList(Edit) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    var directive: ?Directive = null;
    var in_header: bool = true;

    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (line[0] == ':') {
            if (directive != null) {
                try problems.append(arena, .{ .multiple_directives = .{ .line = line_no } });
                continue;
            }
            const body = std.mem.trim(u8, line[1..], " \t");
            const split = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
            const name = body[0..split];
            const argument = std.mem.trim(u8, body[split..], " \t");

            if (std.mem.eql(u8, name, "cd")) {
                if (argument.len == 0) {
                    try problems.append(arena, .{ .directive_needs_argument = .{ .line = line_no, .name = "cd" } });
                    continue;
                }
                directive = .{ .cd = argument };
            } else if (std.mem.eql(u8, name, "open") or std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "e")) {
                if (argument.len == 0) {
                    try problems.append(arena, .{ .directive_needs_argument = .{ .line = line_no, .name = "open" } });
                    continue;
                }
                directive = .{ .open = argument };
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

        var i: usize = 0;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == 0 or (i < line.len and line[i] != ' ' and line[i] != '\t')) {
            if (in_header and isHeaderLine(line)) {
                continue;
            }
            try problems.append(arena, .{ .line_without_id = line_no });
            continue;
        }

        const id = std.fmt.parseInt(u32, line[0..i], 10) catch {
            if (in_header and isHeaderLine(line)) {
                continue;
            }
            try problems.append(arena, .{ .line_without_id = line_no });
            continue;
        };

        var j = i;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        if (j == i and j < line.len) {
            // digitos colados no caminho: nao e uma linha nossa
            if (in_header and isHeaderLine(line)) {
                continue;
            }
            try problems.append(arena, .{ .line_without_id = line_no });
            continue;
        }

        // Uma linha valida de entrada foi encontrada: encerra o cabecalho.
        in_header = false;

        const body = line[j..];
        const path = extractPath(body);
        try edits.append(arena, .{ .id = id, .path = path, .line = line_no });
    }

    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(arena) };
    return .{ .ok = .{ .edits = try edits.toOwnedSlice(arena), .directive = directive } };
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

/// Escreve o buffer que vai para o editor.
/// O cabecalho nao usa caracteres de comentario nem cantos fechados, conectando
/// os titulos a barra vertical atraves do separador '+'.
pub fn writeBuffer(
    w: *std.Io.Writer,
    header: BufferHeader,
    originals: []const Original,
) std.Io.Writer.Error!void {
    if (header.scope) |scope| try w.print("{s}\n", .{scope});
    for (header.notes) |note| try w.print("aviso: {s}\n", .{note});
    for (header.unlistable) |name| {
        try w.writeAll("fora da edicao, nome nao e UTF-8 valido: ");
        for (name) |c| {
            if (c >= 0x20 and c < 0x7f) try w.writeByte(c) else try w.print("\\x{x:0>2}", .{c});
        }
        try w.writeByte('\n');
    }
    // O ID permanece no texto, mas o helper Vim o oculta. As colunas tecnicas
    // ficam a esquerda, com largura fixa; o nome editavel ocupa o fim livre.
    try w.writeAll("──┬───────────┬───────────┬──────────────────┬──────────────────────────\n");
    try w.writeAll("T │ PERMS     │ SIZE      │ MODIFIED         │ NAME\n");
    try w.writeAll("──┼───────────┼───────────┼──────────────────┼──────────────────────────\n");
    for (originals) |o| {
        const slash: []const u8 = if (o.kind == .dir and !std.mem.endsWith(u8, o.path, "/")) "/" else "";
        if (o.display.len > 0) {
            try w.print("{d:0>4}  {s}  {s}{s}\n", .{ o.id, o.display, o.path, slash });
        } else {
            try w.print("{d:0>4}  {s}{s}\n", .{ o.id, o.path, slash });
        }
    }
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{ .arena_state = .init(testing.allocator) };
    }
    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
    }
    fn a(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }
};

fn orig(id: u32, path: []const u8, kind: Kind) Original {
    return .{ .id = id, .path = path, .kind = kind };
}

fn edit(id: u32, path: []const u8) Edit {
    return .{ .id = id, .path = path, .line = id };
}

fn expectProblem(res: Result, comptime tag: std.meta.Tag(Problem)) !void {
    switch (res) {
        .ok => return error.ExpectedInvalidPlan,
        .invalid => |ps| {
            for (ps) |p| if (p == tag) return;
            return error.ProblemNotFound;
        },
    }
}

test "renomeacao simples" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try build(f.a(), &.{orig(1, "a.txt", .file)}, &.{edit(1, "b.txt")}, .{});
    const p = res.ok;
    try testing.expectEqual(@as(usize, 1), p.renames.len);
    try testing.expectEqualStrings("a.txt", p.renames[0].from);
    try testing.expectEqualStrings("b.txt", p.renames[0].to);
    try testing.expectEqual(@as(usize, 0), p.removes.len);
}

test "buffer reordenado nao produz renomeacao" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file), orig(3, "c", .file) };
    // :sort inverteu as linhas; o ID mantem o casamento.
    const edits = [_]Edit{ edit(3, "c"), edit(1, "a"), edit(2, "b") };
    const res = try build(f.a(), &originals, &edits, .{});
    try testing.expect(res.ok.isEmpty());
    try testing.expectEqual(@as(u32, 3), res.ok.unchanged);
}

test "nomes com espaco, acento e TAB sobrevivem" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{
        orig(1, "notas antigas.txt", .file),
        orig(2, "com\tTAB", .file),
    };
    const edits = [_]Edit{
        edit(1, "notas novas (2026).txt"),
        edit(2, "com\tTAB renomeado"),
    };
    const res = try build(f.a(), &originals, &edits, .{});
    try testing.expectEqual(@as(usize, 2), res.ok.renames.len);
}

test "colisao de destino" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file) };
    const edits = [_]Edit{ edit(1, "x"), edit(2, "x") };
    try expectProblem(try build(f.a(), &originals, &edits, .{}), .duplicate_dest);
}

test "destino ocupado por entrada inalterada" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file) };
    const edits = [_]Edit{ edit(1, "b"), edit(2, "b") };
    try expectProblem(try build(f.a(), &originals, &edits, .{}), .duplicate_dest);

    const edits_b = [_]Edit{edit(1, "b")};
    // ID 2 fora do buffer: seria remocao, e o destino de 1 colide com ele.
    try expectProblem(try build(f.a(), &originals, &edits_b, .{}), .dest_occupied_by_removed);
}

test "troca ciclica passa por temporario" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file) };
    const edits = [_]Edit{ edit(1, "b"), edit(2, "a") };
    const p = (try build(f.a(), &originals, &edits, .{})).ok;
    try testing.expectEqual(@as(usize, 3), p.renames.len);
    try testing.expect(p.renames[0].staging);
    try testing.expectEqual(@as(usize, 2), p.moves.len); // o diff nao ve o temporario

    // Simula a execucao para conferir que ninguem sobrescreve ninguem.
    var fs_state: std.StringHashMapUnmanaged(void) = .empty;
    try fs_state.put(f.a(), "a", {});
    try fs_state.put(f.a(), "b", {});
    for (p.renames) |r| {
        try testing.expect(fs_state.remove(r.from));
        try testing.expect(!fs_state.contains(r.to));
        try fs_state.put(f.a(), r.to, {});
    }
    try testing.expect(fs_state.contains("a") and fs_state.contains("b"));
}

test "ciclo de tres" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file), orig(3, "c", .file) };
    const edits = [_]Edit{ edit(1, "b"), edit(2, "c"), edit(3, "a") };
    const p = (try build(f.a(), &originals, &edits, .{})).ok;

    var fs_state: std.StringHashMapUnmanaged(void) = .empty;
    for ([_][]const u8{ "a", "b", "c" }) |n| try fs_state.put(f.a(), n, {});
    for (p.renames) |r| {
        try testing.expect(fs_state.remove(r.from));
        try testing.expect(!fs_state.contains(r.to));
        try fs_state.put(f.a(), r.to, {});
    }
    try testing.expectEqual(@as(u32, 3), fs_state.count());
}

test "cadeia sem ciclo nao usa temporario" {
    var f = Fixture.init();
    defer f.deinit();
    // b -> c precisa acontecer antes de a -> b.
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file) };
    const edits = [_]Edit{ edit(1, "b"), edit(2, "c") };
    const p = (try build(f.a(), &originals, &edits, .{})).ok;
    try testing.expectEqual(@as(usize, 2), p.renames.len);
    for (p.renames) |r| try testing.expect(!r.staging);
    try testing.expectEqualStrings("b", p.renames[0].from);
    try testing.expectEqualStrings("c", p.renames[0].to);
}

test "rename so de caixa sempre passa por temporario" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try build(f.a(), &.{orig(1, "arquivo.txt", .file)}, &.{edit(1, "ARQUIVO.TXT")}, .{});
    const p = res.ok;
    try testing.expectEqual(@as(usize, 2), p.renames.len);
    try testing.expect(p.renames[0].staging);
    try testing.expectEqualStrings("ARQUIVO.TXT", p.renames[1].to);
}

test "criacao de diretorios pai" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try build(f.a(), &.{orig(1, "doc.txt", .file)}, &.{edit(1, "docs/sub/doc.txt")}, .{});
    const p = res.ok;
    try testing.expectEqual(@as(usize, 2), p.mkdirs.len);
    try testing.expectEqualStrings("docs", p.mkdirs[0]);
    try testing.expectEqualStrings("docs/sub", p.mkdirs[1]);
}

test "ID desconhecido, duplicado e linha sem caminho" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{orig(1, "a", .file)};
    try expectProblem(try build(f.a(), &originals, &.{edit(9, "x")}, .{}), .unknown_id);
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(1, "x"), edit(1, "y") }, .{}),
        .duplicate_id,
    );
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "")}, .{}), .id_without_path);
}

test "caminho absoluto, escape do base e nome reservado" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{orig(1, "a", .file)};
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "/etc/passwd")}, .{}), .absolute_path);
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "../fora")}, .{}), .escapes_base);
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "sub/../../fora")}, .{}), .escapes_base);
    try expectProblem(try build(f.a(), &originals, &.{edit(1, ".lst-f-99/x")}, .{}), .reserved_name);
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "./.")}, .{}), .empty_path);
}

test "normalizacao lexical mantem o que e legitimo" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try build(f.a(), &.{orig(1, "a", .file)}, &.{edit(1, "sub/./../b")}, .{});
    try testing.expectEqualStrings("b", res.ok.renames[0].to);
}

test "remocao simples" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file) };
    const p = (try build(f.a(), &originals, &.{edit(1, "a")}, .{})).ok;
    try testing.expectEqual(@as(usize, 1), p.removes.len);
    try testing.expectEqual(@as(u32, 2), p.removes[0].id);
    try testing.expectEqual(@as(u32, 1), p.unchanged);
}

test "pai e filho ambos removidos: absorve o filho" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{
        orig(1, "dir", .dir),
        orig(2, "dir/x.txt", .file),
        orig(3, "dir/sub/y.txt", .file),
    };
    const p = (try build(f.a(), &originals, &.{}, .{})).ok;
    try testing.expectEqual(@as(usize, 1), p.removes.len);
    try testing.expectEqualStrings("dir", p.removes[0].path);
}

test "pai removido com filho renomeado e contradicao" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "dir", .dir), orig(2, "dir/x.txt", .file) };
    try expectProblem(
        try build(f.a(), &originals, &.{edit(2, "dir/y.txt")}, .{}),
        .parent_removed_child_moved,
    );
}

test "pai movido com filho alterado e contradicao" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "dir", .dir), orig(2, "dir/x.txt", .file) };
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(1, "outro"), edit(2, "dir/y.txt") }, .{}),
        .parent_moved_child_touched,
    );
    // Filho inalterado viaja junto com o pai: sem problema.
    const ok = try build(f.a(), &originals, &.{ edit(1, "outro"), edit(2, "dir/x.txt") }, .{});
    try testing.expectEqual(@as(usize, 1), ok.ok.moves.len);
}

test "destino que engole outro destino" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .dir), orig(2, "b", .file) };
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(1, "novo"), edit(2, "novo/b") }, .{}),
        .dest_under_dest,
    );
}

test "parser do buffer" {
    var f = Fixture.init();
    defer f.deinit();
    const text = "# comentario\n" ++
        "0001  a.txt\n" ++
        "0002\tsub/b.txt\n" ++
        "\n" ++
        "0003   nome com  espacos .txt\n";
    const res = try parseBuffer(f.a(), text);
    const edits = res.ok.edits;
    try testing.expectEqual(@as(usize, 3), edits.len);
    try testing.expectEqual(@as(u32, 1), edits[0].id);
    try testing.expectEqualStrings("a.txt", edits[0].path);
    try testing.expectEqualStrings("sub/b.txt", edits[1].path);
    try testing.expectEqualStrings("nome com  espacos .txt", edits[2].path);
    try testing.expectEqual(@as(u32, 5), edits[2].line);
}

test "parser recusa linha sem ID" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try parseBuffer(f.a(), "0001 a.txt\nlixo colado\n");
    switch (res) {
        .ok => return error.ExpectedInvalid,
        .invalid => |ps| try testing.expect(ps[0] == .line_without_id),
    }
}

test "parser preserva espaco no fim do nome" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try parseBuffer(f.a(), "0001  nome com espaco no fim \n");
    try testing.expectEqualStrings("nome com espaco no fim ", res.ok.edits[0].path);
}

test "diretivas de navegacao" {
    var f = Fixture.init();
    defer f.deinit();

    const cd = (try parseBuffer(f.a(), "#\n:cd src\n0001  a.txt\n")).ok;
    try testing.expectEqualStrings("src", cd.directive.?.cd);
    try testing.expectEqual(@as(usize, 1), cd.edits.len);

    const find = (try parseBuffer(f.a(), ":find  plan.zig\n")).ok;
    try testing.expectEqualStrings("plan.zig", find.directive.?.find);

    // :find sem termo e legitimo: abre o buscador na arvore inteira.
    const find_all = (try parseBuffer(f.a(), ":find\n")).ok;
    try testing.expectEqualStrings("", find_all.directive.?.find);

    const open_doc = (try parseBuffer(f.a(), ":open src/main.zig\n")).ok;
    try testing.expectEqualStrings("src/main.zig", open_doc.directive.?.open);

    try testing.expect((try parseBuffer(f.a(), ":undo\n")).ok.directive.? == .undo);
    try testing.expect((try parseBuffer(f.a(), ":refresh\n")).ok.directive.? == .refresh);
    try testing.expect((try parseBuffer(f.a(), ":quit\n")).ok.directive.? == .quit);
    try testing.expect((try parseBuffer(f.a(), ":q\n")).ok.directive.? == .quit);
}

test "diretivas invalidas abortam sem aplicar nada" {
    var f = Fixture.init();
    defer f.deinit();
    const cases = [_]struct { text: []const u8, tag: std.meta.Tag(Problem) }{
        .{ .text = ":voar\n", .tag = .unknown_directive },
        .{ .text = ":cd\n", .tag = .directive_needs_argument },
        .{ .text = ":cd a\n:cd b\n", .tag = .multiple_directives },
    };
    for (cases) |case| {
        switch (try parseBuffer(f.a(), case.text)) {
            .ok => return error.ExpectedInvalid,
            .invalid => |ps| try testing.expect(ps[0] == case.tag),
        }
    }
}

test "nome de arquivo nunca e confundido com diretiva" {
    var f = Fixture.init();
    defer f.deinit();
    // A linha de entrada comeca por digito, entao `:` no nome e so um byte.
    const doc = (try parseBuffer(f.a(), "0001  :cd nao sou diretiva\n")).ok;
    try testing.expect(doc.directive == null);
    try testing.expectEqualStrings(":cd nao sou diretiva", doc.edits[0].path);
}

test "round-trip do buffer" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{
        orig(1, "a b.txt", .file),
        orig(2, "sub/c.md", .file),
    };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBuffer(&w, .{
        .unlistable = &.{"invalido-\xff.txt"},
        .notes = &.{"area orfa .lst-f-1 (2 itens)"},
    }, &originals);
    const res = try parseBuffer(f.a(), w.buffered());
    try testing.expect(res.ok.directive == null);
    const plan_res = try build(f.a(), &originals, res.ok.edits, .{});
    try testing.expect(plan_res.ok.isEmpty());
}

test "round-trip do buffer com colunas preserva somente o nome editavel" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{.{
        .id = 7,
        .path = "antes.txt",
        .kind = .file,
        .display = "- │ rw-r--r-- │      1.1K │ 2026-08-21 21:14 │",
    }};
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBuffer(&w, .{}, &originals);
    const doc = (try parseBuffer(f.a(), w.buffered())).ok;
    try testing.expectEqualStrings("antes.txt", doc.edits[0].path);

    const renamed = (try parseBuffer(f.a(), "0007  - │ rw-r--r-- │      1.1K │ 2026-08-21 21:14 │  depois.txt\n")).ok;
    try testing.expectEqualStrings("depois.txt", renamed.edits[0].path);
}

test "buffer sem linhas iniciadas por '#' mantem cabecalho separado do conteudo" {
    var f = Fixture.init();
    defer f.deinit();
    const text =
        \\lst-f v26.8.21  ~/Devel/lst-f  ·  Neovim
        \\aviso: area orfa .lst-f-100 (1 item)
        \\──┬───────────┬───────────┬──────────────────┬──────────────────────────
        \\T │ PERMS     │ SIZE      │ MODIFIED         │ NAME (editable)
        \\──┼───────────┼───────────┼──────────────────┼──────────────────────────
        \\0001  d │ rwxr-xr-x │         - │ 2026-08-22 13:19 │  src/
        \\0002  - │ rw-r--r-- │      1.1K │ 2026-08-22 13:20 │  build.zig
        \\
    ;
    const res = try parseBuffer(f.a(), text);
    const doc = res.ok;
    try testing.expectEqual(@as(usize, 2), doc.edits.len);
    try testing.expectEqualStrings("src/", doc.edits[0].path);
    try testing.expectEqualStrings("build.zig", doc.edits[1].path);
}

test "cabecalho sem entradas nao acusa erro de linha sem ID" {
    var f = Fixture.init();
    defer f.deinit();
    const text =
        \\lst-f v26.8.21  ~/Devel/lst-f/vazio  ·  Vim
        \\──┬───────────┬───────────┬──────────────────┬──────────────────────────
        \\T │ PERMS     │ SIZE      │ MODIFIED         │ NAME (editable)
        \\──┼───────────┼───────────┼──────────────────┼──────────────────────────
        \\
    ;
    const res = try parseBuffer(f.a(), text);
    try testing.expectEqual(@as(usize, 0), res.ok.edits.len);
}

test "diretiva :hidden eh parseada corretamente" {
    var f = Fixture.init();
    defer f.deinit();

    const t1 = (try parseBuffer(f.a(), "0001  a.txt\n:hidden\n")).ok;
    try testing.expect(t1.directive.? == .hidden);
    try testing.expectEqual(@as(?bool, null), t1.directive.?.hidden);

    const t2 = (try parseBuffer(f.a(), "0001  a.txt\n:hidden on\n")).ok;
    try testing.expectEqual(@as(?bool, true), t2.directive.?.hidden);

    const t3 = (try parseBuffer(f.a(), "0001  a.txt\n:hidden off\n")).ok;
    try testing.expectEqual(@as(?bool, false), t3.directive.?.hidden);
}
