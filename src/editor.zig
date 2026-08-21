//! Contrato universal com o editor, sem plugin, RPC, `--remote` ou `+cmd`:
//! `editor <arquivo_temp>`, em foreground no TTY, esperar sair, reler o
//! arquivo. Sair com codigo diferente de zero (`:cq`) aborta tudo, como no
//! `git commit`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ResolveError = error{
    NoEditor,
    /// Editor que abre janela propria e devolve o terminal na hora: o lst-f
    /// releria o arquivo antes de o usuario ter editado nada.
    NotForeground,
};

pub const Editor = struct {
    argv: []const []const u8,

    pub fn name(e: Editor) []const u8 {
        return std.fs.path.basename(e.argv[0]);
    }
};

/// Editores que nao seguram o terminal. Alguns aceitam uma flag de espera;
/// nesse caso a flag e obrigatoria.
const gui_always = [_][]const u8{ "gvim", "nvim-qt", "mvim", "gedit", "kate", "kwrite", "geany" };
const gui_with_wait = [_][]const u8{ "code", "code-insiders", "codium", "vscodium", "subl", "sublime_text" };
const wait_flags = [_][]const u8{ "--wait", "-w" };

/// Ordem: opcao explicita, `$VISUAL`, `$EDITOR`.
pub fn resolve(
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    explicit: ?[]const u8,
) ResolveError!Editor {
    const spec = explicit orelse
        environ.get("VISUAL") orelse
        environ.get("EDITOR") orelse
        return error.NoEditor;

    const trimmed = std.mem.trim(u8, spec, " \t");
    if (trimmed.len == 0) return error.NoEditor;

    var argv: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |part| argv.append(arena, part) catch return error.NoEditor;

    const editor: Editor = .{ .argv = argv.items };
    try checkForeground(editor);
    return editor;
}

fn checkForeground(e: Editor) ResolveError!void {
    const base = e.name();
    for (gui_always) |bad| {
        if (std.mem.eql(u8, base, bad)) return error.NotForeground;
    }
    for (gui_with_wait) |needs_wait| {
        if (!std.mem.eql(u8, base, needs_wait)) continue;
        for (e.argv[1..]) |arg| {
            for (wait_flags) |flag| {
                if (std.mem.eql(u8, arg, flag)) return;
            }
        }
        return error.NotForeground;
    }
}

pub const RunResult = enum { saved, aborted };

/// Abre `path` no editor, em foreground, herdando o TTY. O terminal volta para
/// o lst-f quando o editor sai.
pub fn run(
    arena: Allocator,
    io: Io,
    e: Editor,
    environ: *const std.process.Environ.Map,
    path: []const u8,
    /// O editor abre com o diretorio-base como cwd, para que `:e`, `gf` e
    /// completacao funcionem sobre os caminhos que estao no buffer.
    cwd: []const u8,
) !RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, e.argv);
    try argv.append(arena, path);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = environ,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| if (code == 0) .saved else .aborted,
        else => .aborted,
    };
}

/// Localiza um executavel no PATH. Nao baixa nem instala nada; so responde se
/// esta la.
pub fn which(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        Io.Dir.cwd().access(io, name, .{}) catch return null;
        return name;
    }
    const path = environ.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = std.fmt.allocPrint(arena, "{s}/{s}", .{ entry, name }) catch return null;
        Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mapWith(gpa: Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    for (pairs) |p| try map.put(p[0], p[1]);
    return map;
}

test "VISUAL tem precedencia sobre EDITOR" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var map = try mapWith(testing.allocator, &.{ .{ "VISUAL", "nvim" }, .{ "EDITOR", "vim" } });
    defer map.deinit();
    const e = try resolve(arena_state.allocator(), &map, null);
    try testing.expectEqualStrings("nvim", e.name());
}

test "opcao explicita vence o ambiente e argumentos sao preservados" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var map = try mapWith(testing.allocator, &.{.{ "EDITOR", "vim" }});
    defer map.deinit();
    const e = try resolve(arena_state.allocator(), &map, "code --wait");
    try testing.expectEqualStrings("code", e.name());
    try testing.expectEqual(@as(usize, 2), e.argv.len);
}

test "editor sem editor configurado" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var map = try mapWith(testing.allocator, &.{});
    defer map.deinit();
    try testing.expectError(error.NoEditor, resolve(arena_state.allocator(), &map, null));
    try testing.expectError(error.NoEditor, resolve(arena_state.allocator(), &map, "   "));
}

test "editores que nao seguram o terminal sao recusados" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var map = try mapWith(testing.allocator, &.{});
    defer map.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.NotForeground, resolve(a, &map, "gvim"));
    try testing.expectError(error.NotForeground, resolve(a, &map, "/usr/bin/nvim-qt"));
    try testing.expectError(error.NotForeground, resolve(a, &map, "code"));
    try testing.expectError(error.NotForeground, resolve(a, &map, "subl"));
    _ = try resolve(a, &map, "subl -w");
    _ = try resolve(a, &map, "vim");
    _ = try resolve(a, &map, "vi");
}
