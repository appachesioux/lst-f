const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const plan = @import("lst_f").plan;
const fsops = @import("lst_f").fsops;
const Applied = fsops.Applied;
const Area = fsops.Area;
const areaName = fsops.areaName;
const openArea = fsops.openArea;
const apply = fsops.apply;
const revert = fsops.revert;
const subtreeCount = fsops.subtreeCount;
const scanOrphans = fsops.scanOrphans;
const processAlive = fsops.processAlive;

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
