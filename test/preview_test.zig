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
