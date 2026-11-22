const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const preview = @import("lst_f").preview;
const isBinary = preview.isBinary;
const hexdump = preview.hexdump;

test "deteccao de binario" {
    try testing.expect(isBinary("texto\x00com nul"));
    try testing.expect(!isBinary("texto normal\ncom quebras\n"));
    try testing.expect(!isBinary("acentuado: cachaca, coracao\n"));
    try testing.expect(isBinary(&[_]u8{ 0x7f, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0 }));
}

test "hexdump alinhado" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try hexdump(&w, "abc");
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "00000000  61 62 63 "));
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "|abc|\n"));
}

test "render lida com arquivo maior que 64 KiB sem StreamTooLong" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Cria arquivo de texto com 80 KiB (maior que o limite de 64 KiB).
    const big = try a.alloc(u8, 80 * 1024);
    @memset(big, 'A');
    big[0] = 'I';
    big[1] = 'N';
    big[2] = 'I';
    big[3] = '\n';
    try tmp.dir.writeFile(io, .{ .sub_path = "grande.txt", .data = big });

    var out: std.Io.Writer.Allocating = .init(a);
    try preview.render(a, io, &out.writer, tmp.dir, "grande.txt");
    const rendered = out.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "StreamTooLong") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "INI\n") != null);
    try testing.expect(std.mem.endsWith(u8, rendered, "...\n"));
}

test "render lida com binario grande, vazio, diretorio, symlink quebrado e ANSI" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const big_bin = try a.alloc(u8, 70 * 1024);
    @memset(big_bin, 0);
    big_bin[0] = 0x7f;
    big_bin[1] = 'E';
    big_bin[2] = 'L';
    big_bin[3] = 'F';
    try tmp.dir.writeFile(io, .{ .sub_path = "grande.bin", .data = big_bin });
    try tmp.dir.writeFile(io, .{ .sub_path = "vazio.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ansi.txt", .data = "ola \x1b[31mvermelho\x1b[0m mundo\n" });
    try tmp.dir.createDir(io, "pasta", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "pasta/item.txt", .data = "ok" });
    try tmp.dir.symLink(io, "alvo-inexistente", "quebrado", .{});

    {
        var out: std.Io.Writer.Allocating = .init(a);
        try preview.render(a, io, &out.writer, tmp.dir, "grande.bin");
        try testing.expect(std.mem.indexOf(u8, out.written(), "binário") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "7f 45 4c 46") != null);
    }
    {
        var out: std.Io.Writer.Allocating = .init(a);
        try preview.render(a, io, &out.writer, tmp.dir, "vazio.txt");
        try testing.expect(std.mem.indexOf(u8, out.written(), "(vazio)") != null);
    }
    {
        var out: std.Io.Writer.Allocating = .init(a);
        try preview.render(a, io, &out.writer, tmp.dir, "ansi.txt");
        try testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[") == null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "ola vermelho mundo\n") != null);
    }
    {
        var out: std.Io.Writer.Allocating = .init(a);
        try preview.render(a, io, &out.writer, tmp.dir, "pasta");
        try testing.expect(std.mem.indexOf(u8, out.written(), "item.txt\n") != null);
    }
    {
        var out: std.Io.Writer.Allocating = .init(a);
        try preview.render(a, io, &out.writer, tmp.dir, "quebrado");
        try testing.expect(std.mem.indexOf(u8, out.written(), "-> alvo-inexistente\n") != null);
    }
}
