const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const plan = @import("lst_f").plan;
const Kind = plan.Kind;
const Original = plan.Original;
const Edit = plan.Edit;
const Create = plan.Create;
const Copy = plan.Copy;
const Problem = plan.Problem;
const Result = plan.Result;
const Plan = plan.Plan;
const BufferDocument = plan.BufferDocument;
const Directive = plan.Directive;
const BufferHeader = plan.BufferHeader;
const build = plan.build;
const isUnder = plan.isUnder;
const suffixed = plan.suffixed;
const normalize = plan.normalize;
const parseBuffer = plan.parseBuffer;
const headerLines = plan.headerLines;
const writeBuffer = plan.writeBuffer;

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

fn creation(line: u32, path: []const u8) Create {
    return .{
        .line = line,
        .path = path,
        .kind = if (path[path.len - 1] == '/') .dir else .file,
    };
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
    const res = try build(f.a(), &.{orig(1, "a.txt", .file)}, &.{edit(1, "b.txt")}, &.{}, .{});
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
    const res = try build(f.a(), &originals, &edits, &.{}, .{});
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
    const res = try build(f.a(), &originals, &edits, &.{}, .{});
    try testing.expectEqual(@as(usize, 2), res.ok.renames.len);
}

test "colisao de destino" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file) };
    const edits = [_]Edit{ edit(1, "x"), edit(2, "x") };
    try expectProblem(try build(f.a(), &originals, &edits, &.{}, .{}), .duplicate_dest);
}

test "destino ocupado por entrada inalterada" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file) };
    const edits = [_]Edit{ edit(1, "b"), edit(2, "b") };
    try expectProblem(try build(f.a(), &originals, &edits, &.{}, .{}), .duplicate_dest);

    const edits_b = [_]Edit{edit(1, "b")};
    // ID 2 fora do buffer e uma remocao; renomear 1 para "b" (o nome do
    // removido) e valido: a remocao e antecipada para liberar o nome.
    const p = (try build(f.a(), &originals, &edits_b, &.{}, .{})).ok;
    try testing.expectEqual(@as(usize, 1), p.removes.len);
    try testing.expectEqual(@as(u32, 2), p.removes[0].id);
    try testing.expectEqual(@as(usize, 1), p.removes_before);
    try testing.expectEqual(@as(usize, 1), p.renames.len);
    try testing.expectEqualStrings("b", p.renames[0].to);
}

test "troca ciclica passa por temporario" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file) };
    const edits = [_]Edit{ edit(1, "b"), edit(2, "a") };
    const p = (try build(f.a(), &originals, &edits, &.{}, .{})).ok;
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
    const p = (try build(f.a(), &originals, &edits, &.{}, .{})).ok;

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
    const p = (try build(f.a(), &originals, &edits, &.{}, .{})).ok;
    try testing.expectEqual(@as(usize, 2), p.renames.len);
    for (p.renames) |r| try testing.expect(!r.staging);
    try testing.expectEqualStrings("b", p.renames[0].from);
    try testing.expectEqualStrings("c", p.renames[0].to);
}

test "rename so de caixa sempre passa por temporario" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try build(f.a(), &.{orig(1, "arquivo.txt", .file)}, &.{edit(1, "ARQUIVO.TXT")}, &.{}, .{});
    const p = res.ok;
    try testing.expectEqual(@as(usize, 2), p.renames.len);
    try testing.expect(p.renames[0].staging);
    try testing.expectEqualStrings("ARQUIVO.TXT", p.renames[1].to);
}

test "criacao de diretorios pai" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try build(f.a(), &.{orig(1, "doc.txt", .file)}, &.{edit(1, "docs/sub/doc.txt")}, &.{}, .{});
    const p = res.ok;
    try testing.expectEqual(@as(usize, 2), p.mkdirs.len);
    try testing.expectEqualStrings("docs", p.mkdirs[0]);
    try testing.expectEqualStrings("docs/sub", p.mkdirs[1]);
}

test "ID desconhecido, duplicado e linha sem caminho" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{orig(1, "a", .file)};
    try expectProblem(try build(f.a(), &originals, &.{edit(9, "x")}, &.{}, .{}), .unknown_id);
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(1, "x"), edit(1, "y") }, &.{}, .{}),
        .duplicate_id,
    );
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "")}, &.{}, .{}), .id_without_path);
}

test "caminho absoluto, escape do base e nome reservado" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{orig(1, "a", .file)};
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "/etc/passwd")}, &.{}, .{}), .absolute_path);
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "../fora")}, &.{}, .{}), .escapes_base);
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "sub/../../fora")}, &.{}, .{}), .escapes_base);
    try expectProblem(try build(f.a(), &originals, &.{edit(1, ".lst-f-99/x")}, &.{}, .{}), .reserved_name);
    try expectProblem(try build(f.a(), &originals, &.{edit(1, "./.")}, &.{}, .{}), .empty_path);
}

test "normalizacao lexical mantem o que e legitimo" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try build(f.a(), &.{orig(1, "a", .file)}, &.{edit(1, "sub/./../b")}, &.{}, .{});
    try testing.expectEqualStrings("b", res.ok.renames[0].to);
}

test "remocao simples" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .file), orig(2, "b", .file) };
    const p = (try build(f.a(), &originals, &.{edit(1, "a")}, &.{}, .{})).ok;
    try testing.expectEqual(@as(usize, 1), p.removes.len);
    try testing.expectEqual(@as(u32, 2), p.removes[0].id);
    try testing.expectEqual(@as(u32, 1), p.unchanged);
}

test "ID duplicado vira copia" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{orig(1, "a.txt", .file)};
    // Duas linhas com o mesmo ID: a da origem e a do destino.
    const edits = [_]Edit{ edit(1, "a.txt"), edit(1, "b.txt") };
    const p = (try build(f.a(), &originals, &edits, &.{}, .{})).ok;
    try testing.expectEqual(@as(usize, 1), p.copies.len);
    try testing.expectEqualStrings("a.txt", p.copies[0].from);
    try testing.expectEqualStrings("b.txt", p.copies[0].to);
    try testing.expectEqual(@as(usize, 0), p.removes.len);
    try testing.expectEqual(@as(usize, 0), p.renames.len);
    try testing.expectEqual(@as(u32, 1), p.unchanged);
}

test "ID duplicado de diretorio exibido com barra vira copia" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{orig(29, "lst-f", .dir)};
    // O caminho interno nao tem a barra que writeBuffer acrescenta a pastas.
    const edits = [_]Edit{ edit(29, "lst-f/"), edit(29, "lst-f-1/") };
    const p = (try build(f.a(), &originals, &edits, &.{}, .{})).ok;
    try testing.expectEqual(@as(usize, 1), p.copies.len);
    try testing.expectEqualStrings("lst-f", p.copies[0].from);
    try testing.expectEqualStrings("lst-f-1", p.copies[0].to);
    try testing.expectEqual(.dir, p.copies[0].kind);
    try testing.expectEqual(@as(usize, 0), p.renames.len);
}

test "ID duplicado no proprio nome pede copia (sufixo fica para o disco)" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{orig(1, "a.txt", .file)};
    const edits = [_]Edit{ edit(1, "a.txt"), edit(1, "a.txt") };
    const p = (try build(f.a(), &originals, &edits, &.{}, .{})).ok;
    try testing.expectEqual(@as(usize, 1), p.copies.len);
    try testing.expectEqualStrings("a.txt", p.copies[0].to);
}

test "ID duplicado com as duas linhas editadas e ambiguo" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{orig(1, "a.txt", .file)};
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(1, "x.txt"), edit(1, "y.txt") }, &.{}, .{}),
        .duplicate_id,
    );
}

test "copia dentro de diretorio removido e contradicao" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "dir", .dir), orig(2, "a.txt", .file) };
    // dir (id 1) removido; a.txt (id 2) copiado para dentro dele.
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(2, "a.txt"), edit(2, "dir/a.txt") }, &.{}, .{}),
        .copy_under_touched,
    );
}

test "sufixo de copia usa dois digitos e zero a esquerda" {
    var f = Fixture.init();
    defer f.deinit();
    try testing.expectEqualStrings("report-01.pdf", try suffixed(f.a(), "report.pdf", 1, false));
    try testing.expectEqualStrings("docs/report-12.pdf", try suffixed(f.a(), "docs/report.pdf", 12, false));
    try testing.expectEqualStrings("dir-01", try suffixed(f.a(), "dir", 1, true));
    try testing.expectEqualStrings(".bashrc-01", try suffixed(f.a(), ".bashrc", 1, false));
}

test "pai e filho ambos removidos: absorve o filho" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{
        orig(1, "dir", .dir),
        orig(2, "dir/x.txt", .file),
        orig(3, "dir/sub/y.txt", .file),
    };
    const p = (try build(f.a(), &originals, &.{}, &.{}, .{})).ok;
    try testing.expectEqual(@as(usize, 1), p.removes.len);
    try testing.expectEqualStrings("dir", p.removes[0].path);
}

test "pai removido com filho renomeado e contradicao" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "dir", .dir), orig(2, "dir/x.txt", .file) };
    try expectProblem(
        try build(f.a(), &originals, &.{edit(2, "dir/y.txt")}, &.{}, .{}),
        .parent_removed_child_moved,
    );
}

test "pai movido com filho alterado e contradicao" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "dir", .dir), orig(2, "dir/x.txt", .file) };
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(1, "outro"), edit(2, "dir/y.txt") }, &.{}, .{}),
        .parent_moved_child_touched,
    );
    // Filho inalterado viaja junto com o pai: sem problema.
    const ok = try build(f.a(), &originals, &.{ edit(1, "outro"), edit(2, "dir/x.txt") }, &.{}, .{});
    try testing.expectEqual(@as(usize, 1), ok.ok.moves.len);
}

test "destino que engole outro destino" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{ orig(1, "a", .dir), orig(2, "b", .file) };
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(1, "novo"), edit(2, "novo/b") }, &.{}, .{}),
        .dest_under_dest,
    );
}

test "criacao monta arquivo, diretorio e os pais que faltam" {
    var f = Fixture.init();
    defer f.deinit();
    const p = (try build(f.a(), &.{}, &.{}, &.{
        creation(5, "novo.txt"),
        creation(6, "docs/sub/nota.md"),
        creation(7, "vazio/"),
    }, .{})).ok;

    // Os pais nao entram em `mkdirs`: aquela fase roda antes das renomeacoes.
    try testing.expectEqual(@as(usize, 0), p.mkdirs.len);
    try testing.expectEqual(@as(usize, 5), p.creates.len);
    try testing.expectEqualStrings("novo.txt", p.creates[0].path);
    try testing.expectEqualStrings("docs", p.creates[1].path);
    try testing.expect(p.creates[1].implicit);
    try testing.expectEqual(Kind.dir, p.creates[1].kind);
    try testing.expectEqualStrings("docs/sub", p.creates[2].path);
    try testing.expectEqualStrings("docs/sub/nota.md", p.creates[3].path);
    try testing.expectEqual(Kind.file, p.creates[3].kind);
    // A barra final some na normalizacao; o tipo que ela pediu fica.
    try testing.expectEqualStrings("vazio", p.creates[4].path);
    try testing.expectEqual(Kind.dir, p.creates[4].kind);
    try testing.expect(!p.creates[4].implicit);
    try testing.expect(!p.isEmpty());
}

test "criacao nao disputa caminho com a selecao" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{
        orig(1, "a.txt", .file),
        orig(2, "dir", .dir),
        orig(3, "dir/x.txt", .file),
    };
    const keep = [_]Edit{ edit(1, "a.txt"), edit(2, "dir"), edit(3, "dir/x.txt") };

    // Entrada que fica onde esta.
    try expectProblem(
        try build(f.a(), &originals, &keep, &.{creation(9, "a.txt")}, .{}),
        .create_occupied,
    );
    // Duas linhas novas com o mesmo nome.
    try expectProblem(
        try build(f.a(), &originals, &keep, &.{ creation(9, "n.txt"), creation(10, "n.txt") }, .{}),
        .create_duplicate,
    );
    // O ID da linha foi apagado por acidente: remove o original e cria um
    // vazio no lugar. Erro, nao perda silenciosa.
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(2, "dir"), edit(3, "dir/x.txt") }, &.{creation(9, "a.txt")}, .{}),
        .create_over_removed,
    );
    // Dentro de diretorio que sai do lugar, o arquivo novo iria junto.
    try expectProblem(
        try build(f.a(), &originals, &.{ edit(1, "a.txt"), edit(2, "outro"), edit(3, "outro/x.txt") }, &.{creation(9, "dir/n.txt")}, .{}),
        .create_under_touched,
    );
    // Dentro de diretorio removido, o arquivo novo iria para a area da sessao.
    try expectProblem(
        try build(f.a(), &originals, &.{edit(1, "a.txt")}, &.{creation(9, "dir/n.txt")}, .{}),
        .create_under_touched,
    );
}

test "criacao ocupa nome que a renomeacao libera" {
    var f = Fixture.init();
    defer f.deinit();
    const p = (try build(
        f.a(),
        &.{orig(1, "log.txt", .file)},
        &.{edit(1, "log.1.txt")},
        &.{creation(9, "log.txt")},
        .{},
    )).ok;
    try testing.expectEqual(@as(usize, 1), p.renames.len);
    try testing.expectEqual(@as(usize, 1), p.creates.len);
    try testing.expectEqualStrings("log.txt", p.creates[0].path);
}

test "regras lexicais da criacao" {
    var f = Fixture.init();
    defer f.deinit();
    try expectProblem(try build(f.a(), &.{}, &.{}, &.{creation(9, "/etc/passwd")}, .{}), .create_absolute);
    try expectProblem(try build(f.a(), &.{}, &.{}, &.{creation(9, "../fora")}, .{}), .create_escapes_base);
    try expectProblem(try build(f.a(), &.{}, &.{}, &.{creation(9, ".lst-f-99/x")}, .{}), .create_reserved);
    try expectProblem(try build(f.a(), &.{}, &.{}, &.{creation(9, "./")}, .{}), .create_empty_path);
}

test "linha nova em diretorio vazio nao e engolida pelo cabecalho" {
    var f = Fixture.init();
    defer f.deinit();
    const scope = "resultado de :find (0 marcada(s))";
    const doc = (try parseBuffer(f.a(), scope ++ "\nrelatorio v2.txt\n", &.{scope})).ok;
    try testing.expectEqual(@as(usize, 0), doc.edits.len);
    try testing.expectEqual(@as(usize, 1), doc.creates.len);
    try testing.expectEqualStrings("relatorio v2.txt", doc.creates[0].path);
}

test "nome novo acima das entradas nao e confundido com cabecalho" {
    var f = Fixture.init();
    defer f.deinit();
    const aviso = "aviso: area orfa .lst-f-1 (1 item)";
    // Nomes que a heuristica antiga engolia: " v", prefixo "lst-f", " · ".
    const text = aviso ++ "\n" ++
        "relatorio v2.txt\n" ++
        "lst-f-notas.md\n" ++
        "/0001  a.txt\n";
    const doc = (try parseBuffer(f.a(), text, &.{aviso})).ok;
    try testing.expectEqual(@as(usize, 1), doc.edits.len);
    try testing.expectEqual(@as(usize, 2), doc.creates.len);
    try testing.expectEqualStrings("relatorio v2.txt", doc.creates[0].path);
    try testing.expectEqualStrings("lst-f-notas.md", doc.creates[1].path);
}

test "cabecalho deslocado por :sort nao vira pedido de criacao" {
    var f = Fixture.init();
    defer f.deinit();
    const scope = "resultado de :find zig (2 marcada(s))";
    const aviso = "aviso: area orfa .lst-f-1 (1 item)";
    // Ordenar o buffer inteiro joga escopo e avisos para depois das entradas;
    // reconhecidos por identidade, continuam sendo cabecalho.
    const text = "/0001  a.txt\n" ++ "/0002  b.txt\n" ++ aviso ++ "\n" ++ scope ++ "\n";
    const doc = (try parseBuffer(f.a(), text, &.{ scope, aviso })).ok;
    try testing.expectEqual(@as(usize, 2), doc.edits.len);
    try testing.expectEqual(@as(usize, 0), doc.creates.len);
}

test "parser do buffer" {
    var f = Fixture.init();
    defer f.deinit();
    const text = "# comentario\n" ++
        "/0001  a.txt\n" ++
        "/0002\tsub/b.txt\n" ++
        "\n" ++
        "/0003   nome com  espacos .txt\n";
    const res = try parseBuffer(f.a(), text, &.{});
    const edits = res.ok.edits;
    try testing.expectEqual(@as(usize, 3), edits.len);
    try testing.expectEqual(@as(u32, 1), edits[0].id);
    try testing.expectEqualStrings("a.txt", edits[0].path);
    try testing.expectEqualStrings("sub/b.txt", edits[1].path);
    try testing.expectEqualStrings("nome com  espacos .txt", edits[2].path);
    try testing.expectEqual(@as(u32, 5), edits[2].line);
}

test "nome novo pode comecar com digitos e espaco" {
    var f = Fixture.init();
    defer f.deinit();
    // A marca do ID e `/` + digitos, e `/` e o unico byte que um nome de
    // arquivo nao pode conter: nenhum nome colide com a forma de uma entrada.
    const doc = (try parseBuffer(f.a(), "/0001  a.txt\n2026 relatorio.txt\n", &.{})).ok;
    try testing.expectEqual(@as(usize, 1), doc.edits.len);
    try testing.expectEqual(@as(u32, 1), doc.edits[0].id);
    try testing.expectEqual(@as(usize, 1), doc.creates.len);
    try testing.expectEqualStrings("2026 relatorio.txt", doc.creates[0].path);
}

test "caminho absoluto em linha nova continua sendo erro" {
    var f = Fixture.init();
    defer f.deinit();
    const doc = (try parseBuffer(f.a(), "/etc/passwd\n", &.{})).ok;
    try testing.expectEqual(@as(usize, 1), doc.creates.len);
    try expectProblem(try build(f.a(), &.{}, &.{}, doc.creates, .{}), .create_absolute);
}

test "linha sem ID vira criacao" {
    var f = Fixture.init();
    defer f.deinit();
    const doc = (try parseBuffer(f.a(), "/0001 a.txt\nnovo.txt\n    sub/dir/\n", &.{})).ok;
    try testing.expectEqual(@as(usize, 1), doc.edits.len);
    try testing.expectEqual(@as(usize, 2), doc.creates.len);
    try testing.expectEqualStrings("novo.txt", doc.creates[0].path);
    try testing.expectEqual(Kind.file, doc.creates[0].kind);
    try testing.expectEqual(@as(u32, 2), doc.creates[0].line);
    // Espaco a esquerda e alinhamento com a coluna NAME.
    try testing.expectEqualStrings("sub/dir/", doc.creates[1].path);
    try testing.expectEqual(Kind.dir, doc.creates[1].kind);
}

test "parser preserva espaco no fim do nome" {
    var f = Fixture.init();
    defer f.deinit();
    const res = try parseBuffer(f.a(), "/0001  nome com espaco no fim \n", &.{});
    try testing.expectEqualStrings("nome com espaco no fim ", res.ok.edits[0].path);
}

test "diretivas de navegacao" {
    var f = Fixture.init();
    defer f.deinit();

    const cd = (try parseBuffer(f.a(), "#\n:cd src\n/0001  a.txt\n", &.{})).ok;
    try testing.expectEqualStrings("src", cd.directive.?.cd);
    try testing.expectEqual(@as(usize, 1), cd.edits.len);

    const find = (try parseBuffer(f.a(), ":find  plan.zig\n", &.{})).ok;
    try testing.expectEqualStrings("plan.zig", find.directive.?.find);

    // :find sem termo e legitimo: abre o buscador na arvore inteira.
    const find_all = (try parseBuffer(f.a(), ":find\n", &.{})).ok;
    try testing.expectEqualStrings("", find_all.directive.?.find);

    const open_doc = (try parseBuffer(f.a(), ":open src/main.zig\n", &.{})).ok;
    try testing.expectEqualStrings("src/main.zig", open_doc.directive.?.open);

    try testing.expect((try parseBuffer(f.a(), ":undo\n", &.{})).ok.directive.? == .undo);
    try testing.expect((try parseBuffer(f.a(), ":refresh\n", &.{})).ok.directive.? == .refresh);
    try testing.expect((try parseBuffer(f.a(), ":quit\n", &.{})).ok.directive.? == .quit);
    try testing.expect((try parseBuffer(f.a(), ":q\n", &.{})).ok.directive.? == .quit);
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
        switch (try parseBuffer(f.a(), case.text, &.{})) {
            .ok => return error.ExpectedInvalid,
            .invalid => |ps| try testing.expect(ps[0] == case.tag),
        }
    }
}

test "nome de arquivo nunca e confundido com diretiva" {
    var f = Fixture.init();
    defer f.deinit();
    // A linha de entrada comeca por digito, entao `:` no nome e so um byte.
    const doc = (try parseBuffer(f.a(), "/0001  :cd nao sou diretiva\n", &.{})).ok;
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
    const head: BufferHeader = .{
        .unlistable = &.{"invalido-\xff.txt"},
        .notes = &.{"area orfa .lst-f-1 (2 itens)"},
    };
    try writeBuffer(f.a(), &w, head, &originals);
    const res = try parseBuffer(f.a(), w.buffered(), try headerLines(f.a(), head));
    try testing.expect(res.ok.directive == null);
    // Nenhuma linha do cabecalho pode ser confundida com pedido de criacao.
    try testing.expectEqual(@as(usize, 0), res.ok.creates.len);
    const plan_res = try build(f.a(), &originals, res.ok.edits, res.ok.creates, .{});
    try testing.expect(plan_res.ok.isEmpty());
}

test "round-trip do buffer com colunas preserva somente o nome editavel" {
    var f = Fixture.init();
    defer f.deinit();
    const originals = [_]Original{.{
        .id = 7,
        .path = "antes.txt",
        .kind = .file,
        .display = "- │ rw-r--r-- │ root     │      1.1K │ 2026-08-21 21:14 │",
    }};
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBuffer(f.a(), &w, .{}, &originals);
    const doc = (try parseBuffer(f.a(), w.buffered(), &.{})).ok;
    try testing.expectEqualStrings("antes.txt", doc.edits[0].path);

    const renamed = (try parseBuffer(f.a(), "/0007  - │ rw-r--r-- │ root     │      1.1K │ 2026-08-21 21:14 │  depois.txt\n", &.{})).ok;
    try testing.expectEqualStrings("depois.txt", renamed.edits[0].path);

    const with_icon = [_]Original{.{
        .id = 8,
        .path = "icone.zig",
        .kind = .file,
        .display = "- │ rw-r--r-- │ root     │      1.1K │ 2026-08-21 21:14 │ ",
    }};
    var icon_buf: [1024]u8 = undefined;
    var icon_w: std.Io.Writer = .fixed(&icon_buf);
    try writeBuffer(f.a(), &icon_w, .{}, &with_icon);
    const icon_doc = (try parseBuffer(f.a(), icon_w.buffered(), &.{})).ok;
    try testing.expectEqualStrings("icone.zig", icon_doc.edits[0].path);

    const icon_renamed = (try parseBuffer(f.a(), "/0008  - │ rw-r--r-- │ root     │      1.1K │ 2026-08-21 21:14 │   depois.zig\n", &.{})).ok;
    try testing.expectEqualStrings("depois.zig", icon_renamed.edits[0].path);
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
        \\/0001  d │ rwxr-xr-x │         - │ 2026-08-22 13:19 │  src/
        \\/0002  - │ rw-r--r-- │      1.1K │ 2026-08-22 13:20 │  build.zig
        \\
    ;
    const res = try parseBuffer(f.a(), text, &.{});
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
    const res = try parseBuffer(f.a(), text, &.{});
    try testing.expectEqual(@as(usize, 0), res.ok.edits.len);
}

test "diretiva :hidden eh parseada corretamente" {
    var f = Fixture.init();
    defer f.deinit();

    const t1 = (try parseBuffer(f.a(), "/0001  a.txt\n:hidden\n", &.{})).ok;
    try testing.expect(t1.directive.? == .hidden);
    try testing.expectEqual(@as(?bool, null), t1.directive.?.hidden);

    const t2 = (try parseBuffer(f.a(), "/0001  a.txt\n:hidden on\n", &.{})).ok;
    try testing.expectEqual(@as(?bool, true), t2.directive.?.hidden);

    const t3 = (try parseBuffer(f.a(), "/0001  a.txt\n:hidden off\n", &.{})).ok;
    try testing.expectEqual(@as(?bool, false), t3.directive.?.hidden);
}
