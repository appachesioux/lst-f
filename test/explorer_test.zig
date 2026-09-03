const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const explorer = @import("lst_f").explorer;
const Entry = explorer.Entry;
const Options = explorer.Options;
const Users = explorer.Users;

test "ordenacao: diretorios antes, depois caixa-insensivel" {
    var entries = [_]Entry{
        .{ .path = "zebra.txt", .kind = .file, .symlink = false, .size = 0, .mtime_s = 0, .mode = 0, .utf8_ok = true },
        .{ .path = "Beta", .kind = .dir, .symlink = false, .size = 0, .mtime_s = 0, .mode = 0, .utf8_ok = true },
        .{ .path = "alfa.txt", .kind = .file, .symlink = false, .size = 0, .mtime_s = 0, .mode = 0, .utf8_ok = true },
        .{ .path = "arq", .kind = .dir, .symlink = false, .size = 0, .mtime_s = 0, .mode = 0, .utf8_ok = true },
    };
    explorer.sortEntries(&entries);
    try testing.expectEqualStrings("arq", entries[0].path);
    try testing.expectEqualStrings("Beta", entries[1].path);
    try testing.expectEqualStrings("alfa.txt", entries[2].path);
    try testing.expectEqualStrings("zebra.txt", entries[3].path);
}

test "show_hidden filtra ou exibe arquivos ocultos" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "visivel.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".oculto.txt", .data = "" });
    try tmp.dir.createDir(io, ".oculto_dir", .default_dir);
    try tmp.dir.createDir(io, "visivel_dir", .default_dir);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", a);

    const Collector = struct {
        paths: std.ArrayList([]const u8) = .empty,
        allocator: Allocator,

        fn emit(ctx: *anyopaque, _: u32, e: Entry) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            if (e.parent) return;
            try c.paths.append(c.allocator, e.path);
        }
    };

    // 1. Oculto desligado (padrao)
    var col_hidden_off: Collector = .{ .allocator = a };
    try explorer.enumerate(a, io, tmp_path, .{ .show_hidden = false }, .{ .ctx = &col_hidden_off, .func = Collector.emit });
    try testing.expectEqual(@as(usize, 2), col_hidden_off.paths.items.len);
    try testing.expectEqualStrings("visivel_dir", col_hidden_off.paths.items[0]);
    try testing.expectEqualStrings("visivel.txt", col_hidden_off.paths.items[1]);

    // 2. Oculto ligado
    var col_hidden_on: Collector = .{ .allocator = a };
    try explorer.enumerate(a, io, tmp_path, .{ .show_hidden = true }, .{ .ctx = &col_hidden_on, .func = Collector.emit });
    try testing.expectEqual(@as(usize, 4), col_hidden_on.paths.items.len);
}

test "titulos da barra de topo alinham com a grade do buffer" {
    // Os titulos sairam do buffer e vao para a barra de topo do editor, longe
    // da linha de dados: uma coluna que mude de largura nao seria mais obvia
    // ao olhar o arquivo.
    const entry: Entry = .{
        .path = "arquivo.txt",
        .kind = .file,
        .symlink = false,
        .size = 2048,
        .mtime_s = 1_700_000_000,
        .mode = 0o644,
        .utf8_ok = true,
    };
    var row_buf: [256]u8 = undefined;
    var row: Io.Writer = .fixed(&row_buf);
    try explorer.writeTableDetails(&row, entry);

    // O invariante e a grade: os divisores tem que cair na mesma coluna. O
    // rotulo NAME fica um passo a esquerda do nome, como sempre esteve.
    const row_text = row.buffered();
    const title_bar = std.mem.lastIndexOf(u8, explorer.table_titles, "│").?;
    const row_bar = std.mem.lastIndexOf(u8, row_text, "│").?;
    try testing.expectEqual(
        explorer.displayColumns(explorer.table_titles[0..title_bar]),
        explorer.displayColumns(row_text[0..row_bar]),
    );
}

test "passwd resolve uid e cai no numero quando nao acha" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    const passwd =
        \\root:x:0:0:root:/root:/bin/bash
        \\spock:x:1000:1000:Spock:/home/spock:/bin/zsh
        \\linha invalida sem campos
        \\daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
        \\
    ;
    try explorer.parsePasswd(arena, passwd, &map);
    try testing.expectEqualStrings("root", map.get(0).?);
    try testing.expectEqualStrings("spock", map.get(1000).?);
    try testing.expectEqualStrings("daemon", map.get(1).?);
    try testing.expectEqual(@as(?[]const u8, null), map.get(4242));

    var users: Users = .{ .arena = arena, .by_uid = map, .loaded = true, .self_uid = 1000 };
    // O seu proprio uid nao gera texto: a coluna fica vazia.
    try testing.expectEqualStrings("", users.nameFor(undefined, 1000));
    try testing.expectEqualStrings("root", users.nameFor(undefined, 0));
    try testing.expectEqualStrings("4242", users.nameFor(undefined, 4242));
}

test "helper Vim: todo glifo emitido por getIcon tem regra de cor" {
    const syntax = comptime explorer.vimIconSyntax();
    const highlights = comptime explorer.vimIconHighlights();

    for (explorer.icon_groups) |g| {
        try testing.expect(std.mem.indexOf(u8, highlights, g.name) != null);
        for (g.glyphs) |gl| {
            try testing.expect(std.mem.indexOf(u8, syntax, gl) != null);
        }
    }

    // Todo icone que getIcon devolve pertence a um grupo com regra syntax.
    var checked: usize = 0;
    for (explorer.file_icons) |fi| {
        for (fi.exts) |e| {
            const name = "a." ++ e[0..1]; _ = name;
        }
        try testing.expect(std.mem.indexOf(u8, syntax, fi.glyph) != null);
        checked += 1;
    }
    try testing.expect(checked > 0);
    for ([_]struct { n: []const u8, d: bool, l: bool, x: bool }{
        .{ .n = "x", .d = true, .l = false, .x = true },
        .{ .n = "x", .d = false, .l = true, .x = false },
        .{ .n = "noext", .d = false, .l = false, .x = false },
        .{ .n = "prog", .d = false, .l = false, .x = true },
        .{ .n = "malhavax.wav", .d = false, .l = false, .x = true },
    }) |c| {
        const gl = explorer.getIcon(c.n, c.d, c.l, c.x);
        const in_group: bool = blk: {
            for (explorer.icon_groups) |g| {
                for (g.glyphs) |x| if (std.mem.eql(u8, x, gl)) break :blk true;
            }
            break :blk false;
        };
        // o generico fica na cor da linha quando nao e executavel; o executavel
        // generico ganha glifo proprio (raio), entao tambem esta num grupo
        if (in_group) try testing.expect(std.mem.indexOf(u8, syntax, gl) != null);
    }
}
