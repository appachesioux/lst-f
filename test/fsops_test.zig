const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const plan = @import("lst_f").plan;
const fsops = @import("lst_f").fsops;
const Applied = fsops.Applied;
const openTrash = fsops.openTrash;
const pruneTrash = fsops.pruneTrash;
const apply = fsops.apply;
const revert = fsops.revert;
const subtreeCount = fsops.subtreeCount;

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
    /// Lixeira dentro do proprio temporario: mesmo filesystem, entao a remocao
    /// passa pelo `rename`, que e o caminho normal.
    fn trash(h: *Harness, pid: std.posix.pid_t) !fsops.Trash {
        return openTrash(h.a(), h.io, h.dir(), "lixeira", pid);
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

test "remocao vai para a lixeira com o nome original e volta no undo" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("some.txt", "adeus");
    const originals = [_]plan.Original{.{ .id = 7, .path = "some.txt", .kind = .file }};
    const p = try planFor(h.a(), &originals, &.{});

    var t = try h.trash(4242);
    defer t.close(io);

    const outcome = try apply(h.a(), io, h.dir(), p, .{ .trash = &t });
    try testing.expect(outcome.failure == null);
    try testing.expect(!h.exists("some.txt"));
    // Nome original na lixeira: e o que faz achar o arquivo depois, sem indice.
    try testing.expectEqualStrings("adeus", try h.read("lixeira/some.txt"));

    const errors = try revert(h.a(), io, h.dir(), outcome.applied, t.dir);
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

    var t = try h.trash(4247);
    defer t.close(io);

    const outcome = try apply(h.a(), io, h.dir(), p, .{ .trash = &t });
    try testing.expect(outcome.failure == null);
    try testing.expectEqualStrings("novo", try h.read("a.txt"));
    try testing.expect(!h.exists("b.txt"));
    try testing.expectEqualStrings("antigo", try h.read("lixeira/a.txt"));

    // O undo restaura a remocao depois de desfazer o rename.
    const errors = try revert(h.a(), io, h.dir(), outcome.applied, t.dir);
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

    var t = try h.trash(4248);
    defer t.close(io);
    // "c" sai do disco depois do plano montado: a remocao dele, que vem por
    // ultimo, falha em FileNotFound e leva o rollback.
    try h.dir().deleteFile(io, "c");

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

    const outcome = try apply(h.a(), io, h.dir(), p, .{ .trash = &t });
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(@as(usize, 0), outcome.rollback_errors.len);
    try testing.expectEqualStrings("A", try h.read("a"));
    try testing.expectEqualStrings("B", try h.read("b"));
    try testing.expect(!h.exists("c"));
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

    var t = try h.trash(4249);
    defer t.close(io);
    // "um" sai do disco: a remocao, que vem depois da copia, falha.
    try h.dir().deleteFile(io, "um");

    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{},
        .creates = &.{},
        .copies = &.{.{ .id = 1, .from = "a.txt", .to = "copia.txt", .kind = .file }},
        .removes = &.{.{ .id = 2, .path = "um", .kind = .file }},
        .moves = &.{},
        .unchanged = 0,
    };
    const outcome = try apply(h.a(), io, h.dir(), p, .{ .trash = &t });
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(@as(usize, 0), outcome.rollback_errors.len);
    try testing.expect(!h.exists("copia.txt"));
    try testing.expect(h.exists("a.txt"));
}

test "mesmo basename de subdiretorios diferentes ganha sufixo na lixeira" {
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

    var t = try h.trash(4243);
    defer t.close(io);
    const outcome = try apply(h.a(), io, h.dir(), p, .{ .trash = &t });
    try testing.expect(outcome.failure == null);
    // O segundo leva o sufixo da copia -- uma convencao de nome no projeto.
    try testing.expectEqualStrings("de x", try h.read("lixeira/nota.txt"));
    try testing.expectEqualStrings("de y", try h.read("lixeira/nota-01.txt"));
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
    var t = try h.trash(4244);
    defer t.close(io);
    const outcome = try apply(h.a(), io, h.dir(), p, .{ .trash = &t });
    try testing.expect(outcome.failure == null);
    try testing.expect(!h.exists("dir"));
    try testing.expectEqualStrings("2", try h.read("lixeira/dir/sub/b"));
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

    var t = try h.trash(4245);
    defer t.close(io);
    // "dois" sai do disco para o segundo remove falhar.
    try h.dir().deleteFile(io, "dois");

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
    const outcome = try apply(h.a(), io, h.dir(), p, .{ .trash = &t });
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(@as(usize, 0), outcome.rollback_errors.len);
    try testing.expectEqualStrings("1", try h.read("um"));
    try testing.expect(!h.exists("dois"));
}

test "remocao dentro da propria lixeira e definitiva" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("velho.txt", "restos");
    try h.dir().createDirPath(io, "pasta/sub");
    try h.touch("pasta/sub/dentro", "mais restos");

    const originals = [_]plan.Original{
        .{ .id = 1, .path = "velho.txt", .kind = .file },
        .{ .id = 2, .path = "pasta", .kind = .dir },
    };
    const p = try planFor(h.a(), &originals, &.{});

    // `.permanent` e o que a CLI passa quando o diretorio-base e a lixeira:
    // e o que permite esvaziar com o gesto de sempre, sem comando novo.
    const outcome = try apply(h.a(), io, h.dir(), p, .permanent);
    try testing.expect(outcome.failure == null);
    try testing.expect(!h.exists("velho.txt"));
    try testing.expect(!h.exists("pasta"));

    // Definitiva nao volta, e o relatorio diz isso em vez de mentir.
    const errors = try revert(h.a(), io, h.dir(), outcome.applied, null);
    try testing.expectEqual(@as(usize, 2), errors.len);
    try testing.expect(!h.exists("velho.txt"));
}

test "poda apaga o que passou da idade e o temporario de sessao morta" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    var t = try h.trash(4250);
    defer t.close(io);
    try h.touch("lixeira/antigo.txt", "1");
    try h.dir().createDirPath(io, "lixeira/pasta");
    try h.touch("lixeira/pasta/dentro", "2");
    // Temporario de PID improvavel de existir: copia interrompida.
    try h.touch("lixeira/.lst-f-tmp-999999-parcial.txt", "3");

    const ns: i96 = std.Io.Clock.now(.real, io).toNanoseconds();
    const now: i64 = @intCast(@divFloor(ns, std.time.ns_per_s));

    // Nada passou da idade ainda: a poda nao toca no que esta no prazo, mas
    // varre o temporario orfao na mesma passada.
    const fresh = pruneTrash(io, t.dir, now, fsops.max_age_s, 4250);
    try testing.expectEqual(@as(usize, 0), fresh.expired);
    try testing.expectEqual(@as(usize, 1), fresh.temps);
    try testing.expect(h.exists("lixeira/antigo.txt"));
    try testing.expect(!h.exists("lixeira/.lst-f-tmp-999999-parcial.txt"));

    // Trinta dias e um segundo depois: sai tudo, arquivo e arvore.
    const aged = pruneTrash(io, t.dir, now + fsops.max_age_s + 1, fsops.max_age_s, 4250);
    try testing.expectEqual(@as(usize, 2), aged.expired);
    try testing.expect(!h.exists("lixeira/antigo.txt"));
    try testing.expect(!h.exists("lixeira/pasta"));
}

test "temporario de sessao viva nao e varrido pela poda" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    var t = try h.trash(4251);
    defer t.close(io);
    const mine = try std.fmt.allocPrint(h.a(), "lixeira/{s}em-curso.txt", .{t.temp_prefix});
    try h.touch(mine, "copia em andamento");

    const ns: i96 = std.Io.Clock.now(.real, io).toNanoseconds();
    const now: i64 = @intCast(@divFloor(ns, std.time.ns_per_s));
    // Mesmo velho, o temporario de uma sessao que esta rodando fica: pode ser
    // uma copia em curso.
    const pruned = pruneTrash(io, t.dir, now + fsops.max_age_s + 1, fsops.max_age_s, 4251);
    try testing.expectEqual(@as(usize, 0), pruned.temps);
    try testing.expect(h.exists(mine));
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

    var t = try h.trash(4246);
    defer t.close(io);
    // "um" sai do disco: a remocao, que vem por ultimo, vai falhar.
    try h.dir().deleteFile(io, "um");

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
    const outcome = try apply(h.a(), io, h.dir(), p, .{ .trash = &t });
    try testing.expect(outcome.failure != null);
    try testing.expectEqual(@as(usize, 0), outcome.rollback_errors.len);
    try testing.expect(!h.exists("novo/x.txt"));
    try testing.expect(!h.exists("novo"));
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

test "aplica e desfaz criacao de symlink e hardlink" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.touch("original.txt", "conteudo do arquivo");

    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{},
        .creates = &.{
            .{ .path = "meu_symlink", .target = "original.txt", .kind = .symlink },
            .{ .path = "meu_hardlink", .target = "original.txt", .kind = .hardlink },
        },
        .copies = &.{},
        .removes = &.{},
        .moves = &.{},
        .unchanged = 0,
    };

    const outcome = try apply(h.a(), io, h.dir(), p, null);
    try testing.expect(outcome.failure == null);
    try testing.expect(h.exists("meu_symlink"));
    try testing.expect(h.exists("meu_hardlink"));
    try testing.expectEqualStrings("conteudo do arquivo", try h.read("meu_symlink"));
    try testing.expectEqualStrings("conteudo do arquivo", try h.read("meu_hardlink"));

    // Desfaz criacao
    const errors = try revert(h.a(), io, h.dir(), outcome.applied, null);
    try testing.expectEqual(@as(usize, 0), errors.len);
    try testing.expect(!h.exists("meu_symlink"));
    try testing.expect(!h.exists("meu_hardlink"));
    try testing.expect(h.exists("original.txt"));
    try testing.expectEqualStrings("conteudo do arquivo", try h.read("original.txt"));
}


test "movimento vindo de outra pasta sai por rename e o undo devolve" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    try h.dir().createDirPath(io, "origem");
    try h.dir().createDirPath(io, "destino");
    try h.touch("origem/a.txt", "conteudo A");

    var destino = try h.dir().openDir(io, "destino", .{ .iterate = true });
    defer destino.close(io);

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var origem = try h.dir().openDir(io, "origem", .{});
    const n = try origem.realPath(io, &buf);
    origem.close(io);
    const from_abs = try std.fmt.allocPrint(h.a(), "{s}/a.txt", .{buf[0..n]});

    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{},
        .removes = &.{},
        .moves = &.{},
        .unchanged = 0,
        .copies = &.{.{
            .id = 7,
            .from = from_abs,
            .to = "a.txt",
            .kind = .file,
            .from_abs = from_abs,
            .cut = true,
        }},
    };

    const outcome = try apply(h.a(), io, destino, p, null);
    try testing.expect(outcome.failure == null);
    // Movimento: chegou aqui e saiu de la.
    try testing.expectEqualStrings("conteudo A", try h.read("destino/a.txt"));
    try testing.expect(!h.exists("origem/a.txt"));

    // O undo devolve, em vez de apagar a copia -- que e o arquivo original.
    const errors = try revert(h.a(), io, destino, outcome.applied, null);
    try testing.expectEqual(@as(usize, 0), errors.len);
    try testing.expect(!h.exists("destino/a.txt"));
    try testing.expectEqualStrings("conteudo A", try h.read("origem/a.txt"));
}

test "movimento entre filesystems copia e apaga a origem, e o undo devolve" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var h = Harness.init(io);
    defer h.deinit();

    // Sem dois filesystems de verdade no teste: o que se verifica e o caminho
    // de codigo do fallback, que nao depende do mount -- copia no destino,
    // depois apaga a origem. Movimento nao passa pela lixeira: o arquivo esta
    // no destino, nao foi perdido.
    try h.dir().createDirPath(io, "origem");
    try h.dir().createDirPath(io, "destino");
    try h.touch("origem/a.txt", "conteudo A");

    var destino = try h.dir().openDir(io, "destino", .{ .iterate = true });
    defer destino.close(io);
    var origem = try h.dir().openDir(io, "origem", .{ .iterate = true });
    defer origem.close(io);

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try origem.realPath(io, &buf);
    const origem_abs = try h.a().dupe(u8, buf[0..n]);
    const from_abs = try std.fmt.allocPrint(h.a(), "{s}/a.txt", .{origem_abs});

    const p: plan.Plan = .{
        .mkdirs = &.{},
        .renames = &.{},
        .removes = &.{},
        .moves = &.{},
        .unchanged = 0,
        .copies = &.{.{
            .id = 7,
            .from = from_abs,
            .to = "a.txt",
            .kind = .file,
            .from_abs = from_abs,
            .cut = true,
            .cross_device = true,
        }},
    };

    const outcome = try apply(h.a(), io, destino, p, null);
    try testing.expect(outcome.failure == null);
    try testing.expectEqualStrings("conteudo A", try h.read("destino/a.txt"));
    try testing.expect(!h.exists("origem/a.txt"));

    // O undo reconstroi a origem a partir da copia, que e a unica instancia.
    const errors = try revert(h.a(), io, destino, outcome.applied, null);
    try testing.expectEqual(@as(usize, 0), errors.len);
    try testing.expect(!h.exists("destino/a.txt"));
    try testing.expectEqualStrings("conteudo A", try h.read("origem/a.txt"));
}
