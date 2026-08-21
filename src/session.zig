//! Estado compartilhado entre o processo principal e os self-exec que o fzf
//! dispara (`--preview-index`, `--reload-toggle`).
//!
//! Nao confundir com a **area de sessao** do `fsops`: aquela e `.lst-f-<pid>/`
//! no diretorio-base, no mesmo filesystem, e existe para o rollback da
//! remocao. Esta aqui e um diretorio de trabalho volatil, e existe so para que
//! nenhum caminho precise ser interpolado em linha de comando de shell: os
//! filhos recebem o caminho deste diretorio pela variavel `LST_F_STATE`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const env_state = "LST_F_STATE";
pub const env_self = "LST_F_SELF";

pub const Mode = enum {
    local,
    recursive,

    pub fn toggle(m: Mode) Mode {
        return switch (m) {
            .local => .recursive,
            .recursive => .local,
        };
    }
};

pub const State = struct {
    path: []const u8,
    dir: Io.Dir,

    pub fn create(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, pid: std.posix.pid_t) !State {
        const tmp = environ.get("TMPDIR") orelse "/tmp";
        const path = try std.fmt.allocPrint(arena, "{s}/lst-f-{d}", .{ tmp, pid });
        Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        return .{ .path = path, .dir = dir };
    }

    pub fn open(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) !State {
        const path = environ.get(env_state) orelse return error.NoSessionState;
        const owned = try arena.dupe(u8, path);
        const dir = try Io.Dir.cwd().openDir(io, owned, .{ .iterate = true });
        return .{ .path = owned, .dir = dir };
    }

    pub fn destroy(s: *State, io: Io) void {
        s.dir.close(io);
        Io.Dir.cwd().deleteTree(io, s.path) catch {};
    }

    pub fn writeBase(s: State, io: Io, base: []const u8) !void {
        try s.dir.writeFile(io, .{ .sub_path = "base", .data = base });
    }

    pub fn readBase(s: State, io: Io, arena: Allocator) ![]const u8 {
        return s.dir.readFileAlloc(io, "base", arena, .limited(Io.Dir.max_path_bytes));
    }

    pub fn writeMode(s: State, io: Io, mode: Mode) !void {
        try s.dir.writeFile(io, .{ .sub_path = "mode", .data = @tagName(mode) });
    }

    pub fn readMode(s: State, io: Io, arena: Allocator) !Mode {
        const text = try s.dir.readFileAlloc(io, "mode", arena, .limited(32));
        return if (std.mem.eql(u8, text, "recursive")) .recursive else .local;
    }

    /// A lista corrente, um caminho por registro, separada por NUL. E o que
    /// resolve o indice do campo 1 do fzf de volta para o caminho, tanto no
    /// processo principal quanto no filho de preview.
    pub fn listFile(s: State, io: Io) !Io.File {
        return s.dir.createFile(io, "list", .{ .truncate = true });
    }

    pub fn readList(s: State, io: Io, arena: Allocator) ![]const []const u8 {
        const raw = s.dir.readFileAlloc(io, "list", arena, .limited(64 * 1024 * 1024)) catch return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, raw, 0);
        while (it.next()) |item| {
            if (item.len == 0) continue;
            try out.append(arena, item);
        }
        return out.toOwnedSlice(arena);
    }
};
