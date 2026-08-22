//! Invocacao do fzf, deteccao de recursos e decodificacao da selecao.
//! Nenhuma regra de filesystem mora aqui.
//!
//! Contrato: um registro por entrada, `--read0`, campo 1 = **indice**, nunca o
//! caminho -- nome de arquivo pode conter TAB e qualquer byte. A saida volta
//! com `--print0` e o indice resolve para o caminho em memoria.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const session = @import("session.zig");
const editor_mod = @import("editor.zig");

/// Piso absoluto, definido por `--preview`/`--preview-window` (ago/2017).
pub const min_version: Version = .{ .major = 0, .minor = 17 };
pub const Version = struct {
    major: u16,
    minor: u16,

    pub fn atLeast(v: Version, other: Version) bool {
        if (v.major != other.major) return v.major > other.major;
        return v.minor >= other.minor;
    }
};

pub const Features = struct {
    version: Version,
    raw: []const u8,
};

pub const DetectError = error{ FzfNotFound, FzfTooOld, FzfUnusable };

pub fn resolveExecutable(arena: Allocator, io: Io, environ: ?*const std.process.Environ.Map) []const u8 {
    if (environ) |env| {
        return editor_mod.which(arena, io, env, "fzf") orelse "fzf";
    }
    return "fzf";
}

/// Uma deteccao por execucao, via `fzf --version`.
pub fn detect(gpa: Allocator, io: Io, environ: ?*const std.process.Environ.Map) !Features {
    const exe = resolveExecutable(gpa, io, environ);
    const result = std.process.run(gpa, io, .{
        .argv = &.{ exe, "--version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FzfNotFound,
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.FzfUnusable,
        else => return error.FzfUnusable,
    }

    const version = parseVersion(result.stdout) orelse return error.FzfUnusable;
    if (!version.atLeast(min_version)) return error.FzfTooOld;

    return .{
        .version = version,
        .raw = try gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \n\r\t")),
    };
}

pub fn parseVersion(text: []const u8) ?Version {
    const trimmed = std.mem.trim(u8, text, " \n\r\t");
    var it = std.mem.splitScalar(u8, trimmed, '.');
    const major_s = it.next() orelse return null;
    const minor_s = it.next() orelse return null;
    const major = std.fmt.parseInt(u16, std.mem.trim(u8, major_s, " v"), 10) catch return null;
    var minor_end: usize = 0;
    while (minor_end < minor_s.len and std.ascii.isDigit(minor_s[minor_end])) minor_end += 1;
    const minor = std.fmt.parseInt(u16, minor_s[0..minor_end], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

pub const Keys = struct {
    pub const preview = "alt-p";
    pub const help = "f1";
    /// Como o fzf nomeia a tecla e como ela e mostrada ao usuario.
    pub const help_label = "F1";
};

pub const Options = struct {
    features: Features,
    header: []const u8,
    prompt: []const u8,
    /// Consulta ja digitada, vinda do `:find <termo>`.
    query: []const u8 = "",
    environ: *const std.process.Environ.Map,
    color: bool,
    preview: bool,
};

pub const Selection = struct {
    key: []const u8,
    indices: []const u32,
    /// O usuario abortou (Esc, Ctrl-C).
    aborted: bool,
};

/// fzf em execucao, com a entrada padrao aberta para receber a lista em
/// streaming.
pub const Runner = struct {
    child: std.process.Child,
    stdin_writer: Io.File.Writer,
    io: Io,
    broken: bool = false,

    pub fn writer(r: *Runner) *Io.Writer {
        return &r.stdin_writer.interface;
    }

    /// Registro pronto: chame depois de escrever `indice \t exibicao`.
    pub fn endRecord(r: *Runner) void {
        const w = r.writer();
        w.writeByte(0) catch {
            r.broken = true;
        };
    }

    /// `true` quando o fzf ja saiu e nao adianta continuar enumerando.
    pub fn isBroken(r: *Runner) bool {
        return r.broken;
    }

    pub fn finish(r: *Runner, arena: Allocator) !Selection {
        r.stdin_writer.interface.flush() catch {};
        if (r.child.stdin) |stdin| {
            stdin.close(r.io);
            r.child.stdin = null;
        }

        var buffer: [4096]u8 = undefined;
        var reader: Io.File.Reader = .init(r.child.stdout.?, r.io, &buffer);
        const out = reader.interface.allocRemaining(arena, .limited(16 * 1024 * 1024)) catch
            try arena.dupe(u8, "");

        const term = try r.child.wait(r.io);
        const code: u8 = switch (term) {
            .exited => |c| c,
            else => 130,
        };
        if (code >= 2) return .{ .key = "", .indices = &.{}, .aborted = true };

        var records = std.mem.splitScalar(u8, out, 0);
        const key = records.next() orelse "";

        var indices: std.ArrayList(u32) = .empty;
        while (records.next()) |record| {
            if (record.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
            const index = std.fmt.parseInt(u32, record[0..tab], 10) catch continue;
            try indices.append(arena, index);
        }
        return .{
            .key = try arena.dupe(u8, std.mem.trim(u8, key, "\n\r")),
            .indices = try indices.toOwnedSlice(arena),
            .aborted = false,
        };
    }
};

pub fn start(arena: Allocator, io: Io, options: Options) !Runner {
    const exe = resolveExecutable(arena, io, options.environ);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe);
    try argv.appendSlice(arena, &.{
        "--read0",
        "--print0",
        "--multi",
        "--reverse",
        "--delimiter=\t",
        "--with-nth=2..",
        "--tiebreak=index",
    });
    try argv.append(arena, try std.fmt.allocPrint(arena, "--prompt={s}", .{options.prompt}));
    try argv.append(arena, try std.fmt.allocPrint(arena, "--header={s}", .{options.header}));
    if (options.color) try argv.append(arena, "--ansi");

    if (options.preview) {
        // Self-exec: o `--preview` do fzf sempre roda em `sh -c`, entao a unica
        // forma de honrar "caminhos sao dados" e nao passar caminho por ali.
        // O binario chega pelo ambiente, expandido pelo proprio shell.
        try argv.append(arena, "--preview=\"$" ++ session.env_self ++ "\" --preview-index {1}");
        // Comeca fechado: a lista e o que se quer ver na maior parte do tempo,
        // e o preview custa um self-exec por movimento de cursor. A sintaxe com
        // `:` e a que o piso 0.17 entende; a com virgula so veio depois.
        try argv.append(arena, "--preview-window=right:50%:hidden");
        try argv.append(arena, "--bind=" ++ Keys.preview ++ ":toggle-preview");
    }

    if (options.query.len > 0) {
        try argv.append(arena, try std.fmt.allocPrint(arena, "--query={s}", .{options.query}));
    }
    // O fzf aqui e um buscador, nao a tela: sai assim que a marcacao esta feita.
    try argv.append(arena, "--expect=enter," ++ Keys.help);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = options.environ,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    const buffer = try arena.alloc(u8, 64 * 1024);
    return .{
        .child = child,
        .stdin_writer = .init(child.stdin.?, io, buffer),
        .io = io,
    };
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse da versao do fzf" {
    try testing.expectEqual(Version{ .major = 0, .minor = 74 }, parseVersion("0.74.3 (15f64c49)").?);
    try testing.expectEqual(Version{ .major = 0, .minor = 17 }, parseVersion("0.17.5\n").?);
    try testing.expectEqual(Version{ .major = 0, .minor = 20 }, parseVersion("0.20.0").?);
    try testing.expect(parseVersion("sem versao") == null);
}

test "piso de versao" {
    try testing.expect((Version{ .major = 0, .minor = 17 }).atLeast(min_version));
    try testing.expect(!(Version{ .major = 0, .minor = 15 }).atLeast(min_version));
    try testing.expect((Version{ .major = 1, .minor = 0 }).atLeast(min_version));
}
