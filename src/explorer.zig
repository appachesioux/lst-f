//! Enumeracao, ordenacao e apresentacao de entradas.
//!
//! Regras estruturais: a area de sessao nunca aparece na lista, e a recursao
//! nao atravessa ponto de montagem nem symlink de diretorio -- e isso que
//! garante filesystem unico para a area de sessao e para os temporarios.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const plan = @import("plan.zig");

pub const max_depth_default: u16 = 16;

pub const Entry = struct {
    /// Relativo ao diretorio-base da listagem.
    path: []const u8,
    kind: plan.Kind,
    /// `true` quando a propria entrada e um link simbolico (nunca seguido).
    symlink: bool,
    size: u64,
    mtime_s: i64,
    mode: u16,
    /// Nome que nao e UTF-8 valido: lista e navega, mas nao vai para o editor.
    utf8_ok: bool,
    /// A entrada sintetica `..`.
    parent: bool = false,
};

pub const Listing = struct {
    /// Caminho absoluto do diretorio-base.
    base: []const u8,
    recursive: bool,
    entries: []const Entry,
};

pub const Options = struct {
    recursive: bool = false,
    max_depth: u16 = max_depth_default,
    icons: bool = false,
    /// Cores discretas via ANSI; o fzf recebe `--ansi` quando ligado.
    color: bool = false,
};

/// Larguras das colunas de exibicao. Ficam aqui, junto de quem escreve as
/// linhas, para que o cabecalho de colunas nunca saia do lugar.
pub const columns = struct {
    pub const kind = 1;
    pub const mode = 9;
    pub const size = 9;
    pub const time = 16;
    pub const gap = "  ";
};

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const dir = "\x1b[1;34m";
    const link = "\x1b[36m";
    const warn = "\x1b[33m";
};

/// Chamado uma vez por entrada, na ordem final. Permite alimentar o fzf em
/// streaming em vez de montar a arvore inteira antes.
pub const Sink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, index: u32, entry: Entry) anyerror!void,

    fn emit(s: Sink, index: u32, entry: Entry) anyerror!void {
        return s.func(s.ctx, index, entry);
    }
};

pub const Error = anyerror;

/// Percorre `base` e entrega as entradas ao `sink`, ja ordenadas.
/// `arena` guarda os caminhos, que sobrevivem a chamada.
pub fn enumerate(
    arena: Allocator,
    io: Io,
    base: []const u8,
    options: Options,
    sink: Sink,
) Error!void {
    var dir = try Io.Dir.cwd().openDir(io, base, .{ .iterate = true });
    defer dir.close(io);

    var index: u32 = 0;

    if (!options.recursive) {
        if (std.fs.path.dirname(base) != null) {
            try sink.emit(index, .{
                .path = "..",
                .kind = .dir,
                .symlink = false,
                .size = 0,
                .mtime_s = 0,
                .mode = 0,
                .utf8_ok = true,
                .parent = true,
            });
            index += 1;
        }
        const entries = try readDir(arena, io, dir, "");
        sortEntries(entries.items);
        for (entries.items) |e| {
            try sink.emit(index, e);
            index += 1;
        }
        return;
    }

    const base_dev = deviceOf(dir.handle, ".") orelse 0;
    try walk(arena, io, dir, "", base_dev, 0, options.max_depth, &index, sink);
}

fn walk(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    prefix: []const u8,
    base_dev: u64,
    depth: u16,
    max_depth: u16,
    index: *u32,
    sink: Sink,
) Error!void {
    const entries = try readDir(arena, io, dir, prefix);
    sortEntries(entries.items);

    for (entries.items) |e| {
        try sink.emit(index.*, e);
        index.* += 1;

        if (e.kind != .dir or e.symlink) continue;
        if (depth + 1 >= max_depth) continue;

        const name = std.fs.path.basename(e.path);
        var name_buf: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
        if (name.len >= name_buf.len) continue;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        if (deviceOf(dir.handle, name_buf[0..name.len :0])) |dev| {
            if (dev != base_dev) continue; // outro ponto de montagem
        }

        var sub = dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
        defer sub.close(io);
        try walk(arena, io, sub, e.path, base_dev, depth + 1, max_depth, index, sink);
    }
}

fn readDir(arena: Allocator, io: Io, dir: Io.Dir, prefix: []const u8) Allocator.Error!std.ArrayList(Entry) {
    var out: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |raw_entry| {
        if (std.mem.startsWith(u8, raw_entry.name, plan.area_prefix)) continue;

        const path = if (prefix.len == 0)
            try arena.dupe(u8, raw_entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, raw_entry.name });

        const st = dir.statFile(io, raw_entry.name, .{ .follow_symlinks = false }) catch null;
        const fs_kind: Io.File.Kind = if (st) |s| s.kind else raw_entry.kind;

        try out.append(arena, .{
            .path = path,
            .kind = switch (fs_kind) {
                .directory => .dir,
                .file => .file,
                .sym_link => blk: {
                    // Link para diretorio ainda lista como diretorio, mas nunca
                    // e seguido na recursao.
                    const target = dir.statFile(io, raw_entry.name, .{ .follow_symlinks = true }) catch break :blk .file;
                    break :blk if (target.kind == .directory) .dir else .file;
                },
                else => .other,
            },
            .symlink = fs_kind == .sym_link,
            .size = if (st) |s| s.size else 0,
            .mtime_s = if (st) |s| s.mtime.toSeconds() else 0,
            .mode = if (st) |s| @truncate(@intFromEnum(s.permissions)) else 0,
            .utf8_ok = std.unicode.utf8ValidateSlice(raw_entry.name),
        });
    }
    return out;
}

fn sortEntries(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, lessThan);
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    const a_dir = a.kind == .dir;
    const b_dir = b.kind == .dir;
    if (a_dir != b_dir) return a_dir;
    const an = std.fs.path.basename(a.path);
    const bn = std.fs.path.basename(b.path);
    const ci = std.ascii.orderIgnoreCase(an, bn);
    if (ci != .eq) return ci == .lt;
    return std.mem.order(u8, an, bn) == .lt;
}

/// Numero do dispositivo do filesystem que contem `sub_path`. `null` quando
/// nao da para saber; nesse caso a recursao segue, e o pior caso e listar um
/// ponto de montagem, nunca perder dado.
fn deviceOf(dir_fd: std.posix.fd_t, sub_path: [:0]const u8) ?u64 {
    if (@import("builtin").os.tag != .linux) return null;
    const linux = std.os.linux;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(
        dir_fd,
        sub_path.ptr,
        linux.AT.SYMLINK_NOFOLLOW,
        .{ .TYPE = true },
        &stx,
    );
    if (linux.errno(rc) != .SUCCESS) return null;
    return (@as(u64, stx.dev_major) << 32) | stx.dev_minor;
}

// ---------------------------------------------------------------------------
// Apresentacao
// ---------------------------------------------------------------------------

/// Linha de exibicao do fzf. Bytes de controle viram `?` -- o campo e so
/// visual, o caminho real vem do indice.
pub fn writeDisplay(w: *Io.Writer, e: Entry, options: Options) Io.Writer.Error!void {
    try writeDetails(w, e, options);
    if (options.icons) {
        try w.writeAll(if (e.kind == .dir) "\u{1F4C1} " else "\u{1F4C4} ");
    }
    if (!e.utf8_ok) {
        if (options.color) try w.writeAll(ansi.warn);
        try w.writeAll("!");
    }
    if (options.color and e.utf8_ok) {
        if (e.symlink) {
            try w.writeAll(ansi.link);
        } else if (e.kind == .dir) {
            try w.writeAll(ansi.dir);
        }
    }
    try writeSafe(w, e.path);
    if (e.kind == .dir) try w.writeByte('/');
    if (e.symlink) try w.writeAll(" @");
    if (options.color) try w.writeAll(ansi.reset);
}

/// Colunas que precedem o nome. Tambem sao usadas no buffer do editor, onde o
/// nome fica depois de um separador para continuar sendo o unico campo editavel.
pub fn writeDetails(w: *Io.Writer, e: Entry, options: Options) Io.Writer.Error!void {
    if (e.parent) {
        if (options.color) try w.writeAll(ansi.dim);
        try w.writeAll("d  ---------          -  ----------------  ");
        if (options.color) try w.writeAll(ansi.reset);
        return;
    }
    if (options.color) try w.writeAll(ansi.dim);
    try w.writeByte(kindChar(e));
    try w.writeAll("  ");
    try writeMode(w, e.mode);
    try w.writeAll("  ");
    try writeSize(w, e);
    try w.writeAll("  ");
    try writeTime(w, e.mtime_s);
    try w.writeAll("  ");
}

/// Metadados para a grade do buffer editavel. Cada campo recebe um divisor
/// vertical '│', conectando-se ao separador '┼' do cabecalho.
pub fn writeTableDetails(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
    try w.writeByte(kindChar(e));
    try w.writeAll(" │ ");
    try writeMode(w, e.mode);
    try w.writeAll(" │ ");
    try writeSize(w, e);
    try w.writeAll(" │ ");
    try writeTime(w, e.mtime_s);
    try w.writeAll(" │");
}

/// Cabecalho de colunas, no estilo de lista do Dolphin ou do Nautilus.
/// Alinha byte a byte com `writeDisplay`, incluindo o deslocamento dos icones.
pub fn writeColumnTitles(w: *Io.Writer, options: Options) Io.Writer.Error!void {
    try writePadded(w, "T", columns.kind);
    try w.writeAll(columns.gap);
    try writePadded(w, "PERMISSAO", columns.mode);
    try w.writeAll(columns.gap);
    try writeRightPadded(w, "TAMANHO", columns.size);
    try w.writeAll(columns.gap);
    try writePadded(w, "MODIFICADO", columns.time);
    try w.writeAll(columns.gap);
    if (options.icons) try w.writeAll("   ");
    try w.writeAll("NOME");
}

fn writePadded(w: *Io.Writer, text: []const u8, width: usize) Io.Writer.Error!void {
    try w.writeAll(text[0..@min(text.len, width)]);
    try w.splatByteAll(' ', width -| text.len);
}

fn writeRightPadded(w: *Io.Writer, text: []const u8, width: usize) Io.Writer.Error!void {
    try w.splatByteAll(' ', width -| text.len);
    try w.writeAll(text[0..@min(text.len, width)]);
}

fn kindChar(e: Entry) u8 {
    if (e.symlink) return 'l';
    return switch (e.kind) {
        .dir => 'd',
        .file => '-',
        .other => '?',
    };
}

fn writeMode(w: *Io.Writer, mode: u16) Io.Writer.Error!void {
    const bits = "rwxrwxrwx";
    var i: u4 = 0;
    while (i < 9) : (i += 1) {
        const bit = @as(u16, 1) << @intCast(8 - i);
        try w.writeByte(if (mode & bit != 0) bits[i] else '-');
    }
}

fn writeSize(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
    if (e.kind == .dir) {
        try w.writeAll("        -");
        return;
    }
    var buf: [16]u8 = undefined;
    const units = [_][]const u8{ "B", "K", "M", "G", "T", "P" };
    var value: f64 = @floatFromInt(e.size);
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    const text = if (unit == 0)
        std.fmt.bufPrint(&buf, "{d}B", .{e.size}) catch "?"
    else if (value < 10)
        std.fmt.bufPrint(&buf, "{d:.1}{s}", .{ value, units[unit] }) catch "?"
    else
        std.fmt.bufPrint(&buf, "{d:.0}{s}", .{ value, units[unit] }) catch "?";
    try w.splatByteAll(' ', 9 -| text.len);
    try w.writeAll(text);
}

fn writeTime(w: *Io.Writer, seconds: i64) Io.Writer.Error!void {
    if (seconds <= 0) {
        try w.writeAll("       -        ");
        return;
    }
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        day.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    });
}

fn writeSafe(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| {
        try w.writeByte(if (c < 0x20 or c == 0x7f) '?' else c);
    }
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ordenacao: diretorios antes, depois caixa-insensivel" {
    var entries = [_]Entry{
        .{ .path = "zebra.txt", .kind = .file, .symlink = false, .size = 0, .mtime_s = 0, .mode = 0, .utf8_ok = true },
        .{ .path = "Beta", .kind = .dir, .symlink = false, .size = 0, .mtime_s = 0, .mode = 0, .utf8_ok = true },
        .{ .path = "alfa.txt", .kind = .file, .symlink = false, .size = 0, .mtime_s = 0, .mode = 0, .utf8_ok = true },
        .{ .path = "arq", .kind = .dir, .symlink = false, .size = 0, .mtime_s = 0, .mode = 0, .utf8_ok = true },
    };
    sortEntries(&entries);
    try testing.expectEqualStrings("arq", entries[0].path);
    try testing.expectEqualStrings("Beta", entries[1].path);
    try testing.expectEqualStrings("alfa.txt", entries[2].path);
    try testing.expectEqualStrings("zebra.txt", entries[3].path);
}

/// Colunas ocupadas no terminal, nao bytes: o icone e um codepoint largo.
fn displayColumns(text: []const u8) usize {
    var total: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return text.len).iterator();
    while (it.nextCodepoint()) |cp| total += if (cp >= 0x1100) 2 else 1;
    return total;
}

test "cabecalho de colunas alinha com a linha de dados" {
    const entry: Entry = .{
        .path = "arquivo.txt",
        .kind = .file,
        .symlink = false,
        .size = 2048,
        .mtime_s = 1_700_000_000,
        .mode = 0o644,
        .utf8_ok = true,
    };
    for ([_]Options{ .{}, .{ .icons = true } }) |options| {
        var title_buf: [256]u8 = undefined;
        var title: Io.Writer = .fixed(&title_buf);
        try writeColumnTitles(&title, options);

        var row_buf: [256]u8 = undefined;
        var row: Io.Writer = .fixed(&row_buf);
        try writeDisplay(&row, entry, options);

        const title_text = title.buffered();
        const row_text = row.buffered();
        const name_col = displayColumns(title_text[0..std.mem.indexOf(u8, title_text, "NOME").?]);
        const value_col = displayColumns(row_text[0..std.mem.indexOf(u8, row_text, "arquivo.txt").?]);
        try testing.expectEqual(name_col, value_col);
    }
}

test "display neutraliza bytes de controle e marca nao-UTF-8" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeDisplay(&w, .{
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
