//! Preview por self-exec (`lst-f --preview-index N`).
//!
//! Arquivo binario nunca aparece como texto bruto: o fallback mostra
//! metadados e o inicio em hexadecimal.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const i18n = @import("i18n.zig");

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
    return renderLang(arena, io, w, base, rel_path, .en);
}

pub fn renderLang(
    arena: Allocator,
    io: Io,
    w: *Io.Writer,
    base: Io.Dir,
    rel_path: []const u8,
    lang: i18n.Lang,
) !void {
    const st = base.statFile(io, rel_path, .{ .follow_symlinks = false }) catch |err| {
        try w.print("{s}\n\n{s}: {s}\n", .{
            rel_path,
            i18n.tr(lang, "could not read", "não foi possível ler"),
            @errorName(err),
        });
        return;
    };

    try w.print("{s}\n", .{rel_path});
    try w.print("{s}  {d} bytes\n", .{ @tagName(st.kind), st.size });
    if (!std.unicode.utf8ValidateSlice(rel_path)) {
        try w.writeAll(i18n.tr(
            lang,
            "name is not valid UTF-8: listed and navigable, but refused by batch edit\n",
            "nome não é UTF-8 válido: lista e navega, mas a edição em lote recusa\n",
        ));
    }
    try w.writeAll("\n");

    switch (st.kind) {
        .sym_link => {
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const n = base.readLink(io, rel_path, &buf) catch {
                try w.writeAll(i18n.tr(
                    lang,
                    "symbolic link (unreadable target)\n",
                    "link simbólico (alvo ilegível)\n",
                ));
                return;
            };
            try w.print("-> {s}\n", .{buf[0..n]});
        },
        .directory => try renderDir(io, w, base, rel_path, lang),
        .file => try renderFile(arena, io, w, base, rel_path, lang),
        else => try w.writeAll(i18n.tr(
            lang,
            "no preview for this entry type\n",
            "sem preview para este tipo de entrada\n",
        )),
    }
}

fn renderDir(io: Io, w: *Io.Writer, base: Io.Dir, rel_path: []const u8, lang: i18n.Lang) !void {
    var dir = base.openDir(io, rel_path, .{ .iterate = true }) catch |err| {
        try w.print("{s}: {s}\n", .{
            i18n.tr(lang, "could not open", "não foi possível abrir"),
            @errorName(err),
        });
        return;
    };
    defer dir.close(io);

    var shown: u32 = 0;
    var truncated = false;
    var it = dir.iterate();
    while (true) {
        const maybe = it.next(io) catch {
            truncated = true;
            break;
        };
        const e = maybe orelse break;
        if (shown >= max_dir_entries) {
            try w.writeAll("...\n");
            break;
        }
        try w.print("{s}{s}\n", .{ e.name, if (e.kind == .directory) "/" else "" });
        shown += 1;
    }
    if (truncated) try w.writeAll(i18n.tr(lang, "(read interrupted)\n", "(leitura interrompida)\n"));
    if (shown == 0 and !truncated) try w.writeAll(i18n.tr(lang, "(empty)\n", "(vazio)\n"));
}

fn renderFile(arena: Allocator, io: Io, w: *Io.Writer, base: Io.Dir, rel_path: []const u8, lang: i18n.Lang) !void {
    const file = base.openFile(io, rel_path, .{}) catch |err| {
        try w.print("{s}: {s}\n", .{
            i18n.tr(lang, "could not read", "não foi possível ler"),
            @errorName(err),
        });
        return;
    };
    defer file.close(io);

    const buf = try arena.alloc(u8, max_text_bytes + 1);
    var io_buf: [4096]u8 = undefined;
    var reader: Io.File.Reader = .init(file, io, &io_buf);
    const n = reader.interface.readSliceShort(buf) catch |err| {
        try w.print("{s}: {s}\n", .{
            i18n.tr(lang, "could not read", "não foi possível ler"),
            @errorName(err),
        });
        return;
    };
    if (n == 0) {
        try w.writeAll(i18n.tr(lang, "(empty)\n", "(vazio)\n"));
        return;
    }
    const truncated_bytes = n > max_text_bytes;
    const data = buf[0..@min(n, max_text_bytes)];
    if (isBinary(data)) {
        try w.writeAll(i18n.tr(lang, "binary — first bytes:\n\n", "binário — primeiros bytes:\n\n"));
        try hexdump(w, data[0..@min(data.len, 256)]);
        return;
    }

    var lines: u32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (lines >= max_lines) {
            try w.writeAll("...\n");
            return;
        }
        try writeSanitizedLine(w, line);
        try w.writeByte('\n');
        lines += 1;
    }
    if (truncated_bytes) try w.writeAll("...\n");
}

fn writeSanitizedLine(w: *Io.Writer, line: []const u8) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == 0x1b) {
            // Descarta sequencias CSI (\x1b[...<final>) e OSC (\x1b]...\x07 ou ST)
            if (i + 1 < line.len and line[i + 1] == '[') {
                i += 2;
                while (i < line.len and (line[i] < 0x40 or line[i] > 0x7e)) : (i += 1) {}
                if (i < line.len) i += 1;
                continue;
            }
            if (i + 1 < line.len and line[i + 1] == ']') {
                i += 2;
                while (i < line.len) : (i += 1) {
                    if (line[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
                continue;
            }
            i += 1;
            continue;
        }
        if (c == '\r') {
            i += 1;
            continue;
        }
        if (c < 0x20 and c != '\t') {
            try w.writeByte('?');
            i += 1;
            continue;
        }
        try w.writeByte(c);
        i += 1;
    }
}

/// NUL no inicio ou byte de controle improvavel: trata como binario. Nao
/// depende de extensao.
pub fn isBinary(data: []const u8) bool {
    const head = data[0..@min(data.len, sniff_bytes)];
    if (std.mem.indexOfScalar(u8, head, 0) != null) return true;
    var suspicious: usize = 0;
    for (head, 0..) |c, i| {
        if (c == 0x1b and i + 1 < head.len and (head[i + 1] == '[' or head[i + 1] == ']')) continue;
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
