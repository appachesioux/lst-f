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
    /// Dono, ja resolvido. Vazio quando e voce: a coluna inteira repetindo o
    /// seu nome nao informa nada na maioria dos diretorios.
    owner: []const u8 = "",
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
    show_hidden: bool = false,
};

/// Resolve uid -> nome lendo `/etc/passwd` uma vez. Sem libc: o alvo de
/// compatibilidade e o binario estatico, entao nada de NSS -- um usuario que so
/// existe em LDAP ou SSSD aparece pelo numero, como no `xpl-f`.
pub const Users = struct {
    arena: Allocator,
    by_uid: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    loaded: bool = false,
    self_uid: u32,

    pub fn init(arena: Allocator) Users {
        return .{
            .arena = arena,
            .self_uid = if (@import("builtin").os.tag == .linux) std.os.linux.getuid() else 0,
        };
    }

    pub fn nameFor(u: *Users, io: Io, uid: u32) []const u8 {
        if (uid == u.self_uid) return "";
        u.load(io);
        if (u.by_uid.get(uid)) |name| return name;
        const fallback = std.fmt.allocPrint(u.arena, "{d}", .{uid}) catch return "";
        u.by_uid.put(u.arena, uid, fallback) catch {};
        return fallback;
    }

    fn load(u: *Users, io: Io) void {
        if (u.loaded) return;
        u.loaded = true;
        const content = Io.Dir.cwd().readFileAlloc(
            io,
            "/etc/passwd",
            u.arena,
            .limited(4 * 1024 * 1024),
        ) catch return;
        parsePasswd(u.arena, content, &u.by_uid) catch {};
    }
};

/// `nome:senha:uid:...` por linha. Separado da leitura para ser testavel.
pub fn parsePasswd(
    arena: Allocator,
    content: []const u8,
    out: *std.AutoHashMapUnmanaged(u32, []const u8),
) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const uid_text = fields.next() orelse continue;
        if (name.len == 0) continue;
        const uid = std.fmt.parseInt(u32, uid_text, 10) catch continue;
        try out.put(arena, uid, name);
    }
}

/// Dono da entrada. `Io.File.Stat` nao expoe uid -- mesma lacuna do `dev` --,
/// entao vai de `statx` cru, so com a mascara do uid.
fn ownerUid(dir_fd: std.posix.fd_t, sub_path: [:0]const u8) ?u32 {
    if (@import("builtin").os.tag != .linux) return null;
    const linux = std.os.linux;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(dir_fd, sub_path.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .UID = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return stx.uid;
}

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
    var users: Users = .init(arena);

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
        const entries = try readDir(arena, io, dir, "", options, &users);
        sortEntries(entries.items);
        for (entries.items) |e| {
            try sink.emit(index, e);
            index += 1;
        }
        return;
    }

    const base_dev = deviceOf(dir.handle, ".") orelse 0;
    try walk(arena, io, dir, "", base_dev, 0, options.max_depth, options, &users, &index, sink);
}

fn walk(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    prefix: []const u8,
    base_dev: u64,
    depth: u16,
    max_depth: u16,
    options: Options,
    users: *Users,
    index: *u32,
    sink: Sink,
) Error!void {
    const entries = try readDir(arena, io, dir, prefix, options, users);
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
        try walk(arena, io, sub, e.path, base_dev, depth + 1, max_depth, options, users, index, sink);
    }
}

fn readDir(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    prefix: []const u8,
    options: Options,
    users: *Users,
) Allocator.Error!std.ArrayList(Entry) {
    var out: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |raw_entry| {
        if (std.mem.eql(u8, raw_entry.name, ".") or std.mem.eql(u8, raw_entry.name, "..")) continue;
        if (std.mem.startsWith(u8, raw_entry.name, plan.area_prefix)) continue;
        if (!options.show_hidden and raw_entry.name.len > 0 and raw_entry.name[0] == '.') continue;

        const path = if (prefix.len == 0)
            try arena.dupe(u8, raw_entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, raw_entry.name });

        const st = dir.statFile(io, raw_entry.name, .{ .follow_symlinks = false }) catch null;
        const fs_kind: Io.File.Kind = if (st) |s| s.kind else raw_entry.kind;

        var name_buf: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
        const owner = owner: {
            if (raw_entry.name.len >= name_buf.len) break :owner "";
            @memcpy(name_buf[0..raw_entry.name.len], raw_entry.name);
            name_buf[raw_entry.name.len] = 0;
            const uid = ownerUid(dir.handle, name_buf[0..raw_entry.name.len :0]) orelse break :owner "";
            break :owner users.nameFor(io, uid);
        };

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
            .mtime_s = if (st) |s| s.ctime.toSeconds() else 0,
            .mode = if (st) |s| @truncate(@intFromEnum(s.permissions)) else 0,
            .utf8_ok = std.unicode.utf8ValidateSlice(raw_entry.name),
            .owner = owner,
        });
    }
    return out;
}

pub fn sortEntries(entries: []Entry) void {
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

/// Titulos da grade do buffer editavel. Nao vao para o buffer: o helper os
/// desenha na barra de topo, que nao rola com a lista nem pode ser editada.
/// Alinham byte a byte com `writeTableDetails`.
pub const table_titles = "T │ PERMS     │ OWNER    │ SIZE      │ SAVED            │ NAME";

/// Cabe `root`, `nobody`, `www-data`. Nome mais longo e truncado: alargar a
/// coluna sai do espaco do nome, que e o que se edita.
const table_owner = 8;

/// Metadados para a grade do buffer editavel. Cada campo recebe um divisor
/// vertical '│'.
pub fn writeTableDetails(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
    try w.writeByte(kindChar(e));
    try w.writeAll(" │ ");
    try writeMode(w, e.mode);
    try w.writeAll(" │ ");
    try writePadded(w, e.owner, table_owner);
    try w.writeAll(" │ ");
    try writeSize(w, e);
    try w.writeAll(" │ ");
    try writeTime(w, e.mtime_s);
    try w.writeAll(" │ ");
    try w.writeAll(getIcon(e.path, e.kind == .dir, e.symlink, e.mode & 0o111 != 0));
}

pub fn writePadded(w: *Io.Writer, text: []const u8, width: usize) Io.Writer.Error!void {
    try w.writeAll(text[0..@min(text.len, width)]);
    try w.splatByteAll(' ', width -| text.len);
}

pub fn writeRightPadded(w: *Io.Writer, text: []const u8, width: usize) Io.Writer.Error!void {
    try w.splatByteAll(' ', width -| text.len);
    try w.writeAll(text[0..@min(text.len, width)]);
}

pub fn kindChar(e: Entry) u8 {
    if (e.symlink) return 'l';
    return switch (e.kind) {
        .dir => 'd',
        .file => '-',
        .symlink => 'l',
        .hardlink => '-',
        .other => '?',
    };
}

pub fn writeMode(w: *Io.Writer, mode: u16) Io.Writer.Error!void {
    const bits = "rwxrwxrwx";
    var i: u4 = 0;
    while (i < 9) : (i += 1) {
        const bit = @as(u16, 1) << @intCast(8 - i);
        try w.writeByte(if (mode & bit != 0) bits[i] else '-');
    }
}

pub fn writeSize(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
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

pub var tz_offset_seconds: i32 = 0;

pub fn writeTime(w: *Io.Writer, seconds: i64) Io.Writer.Error!void {
    if (seconds <= 0) {
        try w.writeAll("       -        ");
        return;
    }
    const local_seconds = seconds + tz_offset_seconds;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(local_seconds) };
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

/// Colunas ocupadas no terminal, nao bytes: o icone e um codepoint largo.
pub fn displayColumns(text: []const u8) usize {
    var total: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return text.len).iterator();
    while (it.nextCodepoint()) |cp| total += if (cp >= 0x1100) 2 else 1;
    return total;
}

/// Icones e classes de cor. Uma unica tabela alimenta o `getIcon`, as regras
/// de `syntax match` do helper Vim e as sequencias ANSI da busca fzf: e o que
/// impede os tres lados de divergirem no glifo.
pub const glyphs = struct {
    pub const dir = "\xef\x84\x95"; //
    pub const link = "\xef\x92\x81"; //
    pub const generic = "\xef\x85\x9b"; //
    pub const zig = "\xee\x9a\xa9"; //
    pub const c = "\xee\x98\x9e"; //
    pub const cpp = "\xee\x98\x9d"; //
    pub const rust = "\xee\x9e\xa8"; //
    pub const go = "\xee\x98\xa7"; //
    pub const py = "\xee\x98\x86"; //
    pub const js = "\xee\x9e\x81"; //
    pub const ts = "\xee\x98\xa8"; //
    pub const json = "\xee\x98\x8b"; //
    pub const md = "\xef\x92\x8a"; //
    pub const img = "\xef\x80\xbe"; //
    pub const pdf = "\xef\x87\x81"; //
    pub const zip = "\xef\x90\x90"; //
    pub const txt = "\xef\x85\x9c"; //
    pub const sh = "\xef\x92\x89"; //
    pub const exec = "\xef\x83\xa7"; // nf-fa-bolt: arquivo executavel sem extensao conhecida
    pub const vim = "\xee\x98\xab"; //
    pub const sql = "\xef\x87\x80"; //
    pub const sheet = "\xef\x87\x83"; //
    pub const config = "\xef\x83\x9a"; //
    pub const log = "\xef\x83\xb6"; // nf-fa-file_text_o
    pub const music = "\xef\x80\x81"; // nf-fa-music
    pub const video = "\xef\x80\x88"; // nf-fa-film
};

pub const IconGroup = struct {
    /// sufixo do grupo de destaque no Vim: LstfIcon<name>
    name: []const u8,
    cterm: []const u8,
    gui: []const u8,
    cterm_light: []const u8,
    gui_light: []const u8,
    /// ANSI para a busca fzf; '' deixa o icone na cor da linha
    fzf: []const u8 = "",
    glyphs: []const []const u8 = &.{},
};

pub const icon_groups = [_]IconGroup{
    .{ .name = "Dir", .cterm = "cterm=bold ctermfg=12", .gui = "gui=bold guifg=#61afef", .cterm_light = "cterm=bold ctermfg=4", .gui_light = "gui=bold guifg=#1e66f5", .fzf = "\x1b[1;34m", .glyphs = &.{glyphs.dir} },
    .{ .name = "Link", .cterm = "cterm=italic ctermfg=14", .gui = "gui=italic guifg=#56b6c2", .cterm_light = "cterm=italic ctermfg=6", .gui_light = "gui=italic guifg=#179299", .fzf = "\x1b[36m", .glyphs = &.{glyphs.link} },
    .{ .name = "Exec", .cterm = "cterm=bold ctermfg=10", .gui = "gui=bold guifg=#a6d189", .cterm_light = "cterm=bold ctermfg=2", .gui_light = "gui=bold guifg=#40a02b", .fzf = "\x1b[1;32m", .glyphs = &.{ glyphs.sh, glyphs.vim, glyphs.exec } },
    .{ .name = "Zig", .cterm = "cterm=bold ctermfg=9", .gui = "gui=bold guifg=#fab387", .cterm_light = "cterm=bold ctermfg=9", .gui_light = "gui=bold guifg=#fe640b", .fzf = "\x1b[38;5;209m", .glyphs = &.{glyphs.zig} },
    .{ .name = "Code", .cterm = "ctermfg=13", .gui = "guifg=#cba6f7", .cterm_light = "ctermfg=5", .gui_light = "guifg=#8839ef", .fzf = "\x1b[35m", .glyphs = &.{ glyphs.c, glyphs.cpp, glyphs.rust, glyphs.go, glyphs.js, glyphs.ts } },
    .{ .name = "Python", .cterm = "ctermfg=11", .gui = "guifg=#f9e2af", .cterm_light = "ctermfg=3", .gui_light = "guifg=#df8e1d", .fzf = "\x1b[33m", .glyphs = &.{glyphs.py} },
    .{ .name = "Data", .cterm = "ctermfg=3", .gui = "guifg=#e5c07b", .cterm_light = "ctermfg=130", .gui_light = "guifg=#b87333", .fzf = "\x1b[38;5;180m", .glyphs = &.{ glyphs.json, glyphs.sql, glyphs.sheet, glyphs.config, glyphs.log } },
    .{ .name = "Doc", .cterm = "cterm=bold ctermfg=15", .gui = "gui=bold guifg=#cdd6f4", .cterm_light = "cterm=bold ctermfg=240", .gui_light = "gui=bold guifg=#5c5f77", .fzf = "\x1b[1;37m", .glyphs = &.{ glyphs.md, glyphs.txt } },
    .{ .name = "Image", .cterm = "ctermfg=5", .gui = "guifg=#f5c2e7", .cterm_light = "ctermfg=5", .gui_light = "guifg=#ea76cb", .fzf = "\x1b[38;5;218m", .glyphs = &.{glyphs.img} },
    .{ .name = "Binary", .cterm = "ctermfg=9", .gui = "guifg=#f38ba8", .cterm_light = "ctermfg=1", .gui_light = "guifg=#d20f39", .fzf = "\x1b[38;5;210m", .glyphs = &.{ glyphs.pdf, glyphs.zip } },
    .{ .name = "Music", .cterm = "ctermfg=4", .gui = "guifg=#b4befe", .cterm_light = "ctermfg=4", .gui_light = "guifg=#7287fd", .fzf = "\x1b[38;5;147m", .glyphs = &.{glyphs.music} },
    .{ .name = "Video", .cterm = "ctermfg=6", .gui = "guifg=#94e2d5", .cterm_light = "ctermfg=6", .gui_light = "guifg=#209fb5", .fzf = "\x1b[38;5;116m", .glyphs = &.{glyphs.video} },
};

/// Extensao -> glifo. A ordem manda: a primeira coincidencia vence.
pub const file_icons = [_]struct { exts: []const []const u8, glyph: []const u8 }{
    .{ .exts = &.{ "zig", "zon" }, .glyph = glyphs.zig },
    .{ .exts = &.{ "c", "h" }, .glyph = glyphs.c },
    .{ .exts = &.{ "cpp", "hpp" }, .glyph = glyphs.cpp },
    .{ .exts = &.{"rs"}, .glyph = glyphs.rust },
    .{ .exts = &.{"go"}, .glyph = glyphs.go },
    .{ .exts = &.{"py"}, .glyph = glyphs.py },
    .{ .exts = &.{"js"}, .glyph = glyphs.js },
    .{ .exts = &.{"ts"}, .glyph = glyphs.ts },
    .{ .exts = &.{"json"}, .glyph = glyphs.json },
    .{ .exts = &.{"md"}, .glyph = glyphs.md },
    .{ .exts = &.{ "png", "jpg", "jpeg", "gif", "svg" }, .glyph = glyphs.img },
    .{ .exts = &.{"pdf"}, .glyph = glyphs.pdf },
    .{ .exts = &.{ "zip", "tar", "gz", "xz" }, .glyph = glyphs.zip },
    .{ .exts = &.{"txt"}, .glyph = glyphs.txt },
    .{ .exts = &.{ "sh", "bash", "zsh" }, .glyph = glyphs.sh },
    .{ .exts = &.{"vim"}, .glyph = glyphs.vim },
    .{ .exts = &.{"sql"}, .glyph = glyphs.sql },
    .{ .exts = &.{ "xlsx", "xls", "csv" }, .glyph = glyphs.sheet },
    .{ .exts = &.{ "toml", "yaml", "yml", "ini" }, .glyph = glyphs.config },
    .{ .exts = &.{ "log" }, .glyph = glyphs.log },
    .{ .exts = &.{ "mp3", "wav", "flac", "ogg", "oga", "m4a", "opus", "aac" }, .glyph = glyphs.music },
    .{ .exts = &.{ "mp4", "mkv", "avi", "mov", "webm", "m4v", "mpg", "mpeg" }, .glyph = glyphs.video },
};

/// `is_exec` so entra quando nem diretorio nem link: o raio marca o binario
/// executavel cuja extensao nao tem glifo proprio -- sem ele, o coitado
/// chegaria com o generico e ficaria sem cor, porque a cor mora no glifo.
pub fn getIcon(name: []const u8, is_dir: bool, is_link: bool, is_exec: bool) []const u8 {
    if (is_link) return glyphs.link;
    if (is_dir) return glyphs.dir;

    const ext_idx = std.mem.lastIndexOfScalar(u8, name, '.') orelse
        return if (is_exec) glyphs.exec else glyphs.generic;
    const ext = name[ext_idx + 1 ..];

    for (file_icons) |fi| {
        for (fi.exts) |e| {
            if (std.mem.eql(u8, ext, e)) return fi.glyph;
        }
    }

    return if (is_exec) glyphs.exec else glyphs.generic;
}

/// ANSI da classe do icone, para a busca fzf; null no generico, que fica na
/// cor da linha.
pub fn iconAnsi(glyph: []const u8) ?[]const u8 {
    for (icon_groups) |g| {
        for (g.glyphs) |x| {
            if (std.mem.eql(u8, x, glyph)) return if (g.fzf.len > 0) g.fzf else null;
        }
    }
    return null;
}

/// Linhas `highlight` dos grupos de icone, geradas da mesma tabela que
/// `getIcon`: trocar uma cor ou um glifo ali atualiza as duas pontas.
pub fn vimIconHighlightsDark() []const u8 {
    @setEvalBranchQuota(100_000);
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    buf[0] = '\n';
    n = 1;
    inline for (icon_groups) |g| {
        const line = "    highlight LstfIcon" ++ g.name ++ " " ++ g.cterm ++ " " ++ g.gui ++ "\n";
        @memcpy(buf[n .. n + line.len], line);
        n += line.len;
    }
    const finalized: [4096]u8 = buf;
    return finalized[0..n];
}

pub fn vimIconHighlightsLight() []const u8 {
    @setEvalBranchQuota(100_000);
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    buf[0] = '\n';
    n = 1;
    inline for (icon_groups) |g| {
        const line = "    highlight LstfIcon" ++ g.name ++ " " ++ g.cterm_light ++ " " ++ g.gui_light ++ "\n";
        @memcpy(buf[n .. n + line.len], line);
        n += line.len;
    }
    const finalized: [4096]u8 = buf;
    return finalized[0..n];
}

pub fn vimIconHighlights() []const u8 {
    return vimIconHighlightsDark();
}

/// Regras `syntax match` que pintam so o glifo do icone. O glifo e de uso
/// privado (PUA) e unico por grupo, entao ele mesmo basta como âncora: nao ha
/// porque casar o `│ ` anterior -- e nao se pode: o `LstfSep` ja consome cada
/// divisor como item contido, e regra contida nao pode comecar em ponto ja
/// coberto por outra; por isso a cor mora no glifo, e o binario executavel sem
/// extensao conhecida ganha glifo proprio em `getIcon` (um override que olhasse
/// a permissao `x` na linha nunca casaria: o unico ponto livre antes do icone
/// generico esta atras das barras). O `containedin` ancora a regra na linha,
/// ja colorida de forma neutra.
pub fn vimIconSyntax() []const u8 {
    @setEvalBranchQuota(100_000);
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    const put = struct {
        fn at(b: *[4096]u8, idx: *usize, s: []const u8) void {
            @memcpy(b[idx.* .. idx.* + s.len], s);
            idx.* += s.len;
        }
    }.at;
    put(&buf, &n, "\n  silent! syntax clear");
    inline for (icon_groups) |g| put(&buf, &n, " LstfIcon" ++ g.name);
    put(&buf, &n, "\n");
    inline for (icon_groups) |g| {
        put(&buf, &n, "  syntax match LstfIcon" ++ g.name ++ " /\\%(");
        for (g.glyphs, 0..) |gl, i| {
            if (i != 0) put(&buf, &n, "\\|");
            put(&buf, &n, gl);
        }
        put(&buf, &n, "\\)/ containedin=LstfFile\n");
    }
    const finalized: [4096]u8 = buf; // desvincula do comptime var
    return finalized[0..n];
}
