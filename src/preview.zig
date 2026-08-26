//! Preview por self-exec (`lst-f --preview-index N`).
//!
//! Arquivo binario nunca aparece como texto bruto: o fallback mostra
//! metadados e o inicio em hexadecimal.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_text_bytes = 64 * 1024;
const max_lines = 300;
const max_dir_entries = 200;
const sniff_bytes = 4096;

pub fn render(
    arena: Allocator,
    io: Io,
    w: *Io.Writer,
    base: Io.Dir,
    rel_path: []const u8,
) !void {
    const st = base.statFile(io, rel_path, .{ .follow_symlinks = false }) catch |err| {
        try w.print("{s}\n\nnao foi possivel ler: {s}\n", .{ rel_path, @errorName(err) });
        return;
    };

    try w.print("{s}\n", .{rel_path});
    try w.print("{s}  {d} bytes\n", .{ @tagName(st.kind), st.size });
    if (!std.unicode.utf8ValidateSlice(rel_path)) {
        try w.writeAll("nome nao e UTF-8 valido: lista e navega, mas a edicao em lote recusa\n");
    }
    try w.writeAll("\n");

    switch (st.kind) {
        .sym_link => {
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const n = base.readLink(io, rel_path, &buf) catch {
                try w.writeAll("link simbolico (alvo ilegivel)\n");
                return;
            };
            try w.print("-> {s}\n", .{buf[0..n]});
        },
        .directory => try renderDir(io, w, base, rel_path),
        .file => try renderFile(arena, io, w, base, rel_path),
        else => try w.writeAll("sem preview para este tipo de entrada\n"),
    }
}

fn renderDir(io: Io, w: *Io.Writer, base: Io.Dir, rel_path: []const u8) !void {
    var dir = base.openDir(io, rel_path, .{ .iterate = true }) catch |err| {
        try w.print("nao foi possivel abrir: {s}\n", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var shown: u32 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (shown >= max_dir_entries) {
            try w.writeAll("...\n");
            break;
        }
        try w.print("{s}{s}\n", .{ e.name, if (e.kind == .directory) "/" else "" });
        shown += 1;
    }
    if (shown == 0) try w.writeAll("(vazio)\n");
}

fn renderFile(arena: Allocator, io: Io, w: *Io.Writer, base: Io.Dir, rel_path: []const u8) !void {
    const data = base.readFileAlloc(io, rel_path, arena, .limited(max_text_bytes)) catch |err| {
        try w.print("nao foi possivel ler: {s}\n", .{@errorName(err)});
        return;
    };
    if (data.len == 0) {
        try w.writeAll("(vazio)\n");
        return;
    }
    if (isBinary(data)) {
        try w.writeAll("binario -- primeiros bytes:\n\n");
        try hexdump(w, data[0..@min(data.len, 256)]);
        return;
    }

    var lines: u32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (lines >= max_lines) {
            try w.writeAll("...\n");
            break;
        }
        try w.writeAll(line);
        try w.writeByte('\n');
        lines += 1;
    }
}

/// NUL no inicio ou byte de controle improvavel: trata como binario. Nao
/// depende de extensao.
pub fn isBinary(data: []const u8) bool {
    const head = data[0..@min(data.len, sniff_bytes)];
    if (std.mem.indexOfScalar(u8, head, 0) != null) return true;
    var suspicious: usize = 0;
    for (head) |c| {
        if (c < 0x09 or (c > 0x0d and c < 0x20)) suspicious += 1;
    }
    return suspicious * 32 > head.len;
}

pub fn hexdump(w: *Io.Writer, data: []const u8) Io.Writer.Error!void {
    var offset: usize = 0;
    while (offset < data.len) : (offset += 16) {
        const row = data[offset..@min(offset + 16, data.len)];
        try w.print("{x:0>8}  ", .{offset});
        for (0..16) |i| {
            if (i < row.len) try w.print("{x:0>2} ", .{row[i]}) else try w.writeAll("   ");
            if (i == 7) try w.writeByte(' ');
        }
        try w.writeAll(" |");
        for (row) |c| try w.writeByte(if (c >= 0x20 and c < 0x7f) c else '.');
        try w.writeAll("|\n");
    }
}

