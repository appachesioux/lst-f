const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const fzf = @import("lst_f").fzf;
const explorer = @import("lst_f").explorer;

test "parse da versao do fzf" {
    try testing.expectEqual(fzf.Version{ .major = 0, .minor = 74 }, fzf.parseVersion("0.74.3 (15f64c49)").?);
    try testing.expectEqual(fzf.Version{ .major = 0, .minor = 17 }, fzf.parseVersion("0.17.5\n").?);
    try testing.expectEqual(fzf.Version{ .major = 0, .minor = 20 }, fzf.parseVersion("0.20.0").?);
    try testing.expect(fzf.parseVersion("sem versao") == null);
}

test "piso de versao" {
    try testing.expect((fzf.Version{ .major = 0, .minor = 17 }).atLeast(fzf.min_version));
    try testing.expect(!(fzf.Version{ .major = 0, .minor = 15 }).atLeast(fzf.min_version));
    try testing.expect((fzf.Version{ .major = 1, .minor = 0 }).atLeast(fzf.min_version));
}

test "cabecalho de colunas alinha com a linha de dados" {
    const entry: explorer.Entry = .{
        .path = "arquivo.txt",
        .kind = .file,
        .symlink = false,
        .size = 2048,
        .mtime_s = 1_700_000_000,
        .mode = 0o644,
        .utf8_ok = true,
    };
    for ([_]explorer.Options{ .{}, .{ .icons = true } }) |options| {
        var title_buf: [256]u8 = undefined;
        var title: Io.Writer = .fixed(&title_buf);
        try fzf.writeColumnTitles(&title, options);

        var row_buf: [256]u8 = undefined;
        var row: Io.Writer = .fixed(&row_buf);
        try fzf.writeDisplay(&row, entry, options);

        const title_text = title.buffered();
        const row_text = row.buffered();
        const name_col = explorer.displayColumns(title_text[0..std.mem.indexOf(u8, title_text, "NAME").?]);
        const value_col = explorer.displayColumns(row_text[0..std.mem.indexOf(u8, row_text, "arquivo.txt").?]);
        try testing.expectEqual(name_col, value_col);
    }
}

test "display neutraliza bytes de controle e marca nao-UTF-8" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try fzf.writeDisplay(&w, .{
        .path = "com\tTAB",
        .kind = .file,
        .symlink = false,
        .size = 2048,
        .mtime_s = 0,
        .mode = 0o644,
        .utf8_ok = false,
    }, .{});
    const out = w.buffered();
    try testing.expect(std.mem.indexOfScalar(u8, out, '\t') == null);
    try testing.expect(std.mem.indexOf(u8, out, "com?TAB") != null);
    try testing.expect(std.mem.indexOf(u8, out, "!com") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2.0K") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rw-r--r--") != null);
}
