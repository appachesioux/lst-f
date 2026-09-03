const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const editor_mod = @import("lst_f").editor;
const resolve = editor_mod.resolve;
const which = editor_mod.which;

fn mapWith(gpa: Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    for (pairs) |p| try map.put(p[0], p[1]);
    return map;
}

test "opcao explicita vence e argumentos sao preservados" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var map = try mapWith(testing.allocator, &.{});
    defer map.deinit();
    const e = try resolve(arena_state.allocator(), io, &map, "code --wait");
    try testing.expectEqualStrings("code", e.name());
    try testing.expectEqual(@as(usize, 2), e.argv.len);
}

test "busca automatica: vim e escolhido mesmo com nvim no PATH" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "vim", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nvim", .data = "" });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", a);

    // Mesmo com VISUAL ou EDITOR setados para outro editor, eles sao ignorados
    var map = try mapWith(testing.allocator, &.{
        .{ "PATH", tmp_path },
        .{ "VISUAL", "outro" },
        .{ "EDITOR", "outro" },
    });
    defer map.deinit();

    const e = try resolve(a, io, &map, null);
    try testing.expectEqualStrings("vim", e.name());
}

test "busca automatica nao escolhe nvim" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "nvim", .data = "" });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", a);

    var map = try mapWith(testing.allocator, &.{
        .{ "PATH", tmp_path },
    });
    defer map.deinit();

    try testing.expectError(error.NoEditor, resolve(a, io, &map, null));
}

test "editor sem vim nem nvim no PATH" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", a);

    var map = try mapWith(testing.allocator, &.{
        .{ "PATH", tmp_path },
    });
    defer map.deinit();

    try testing.expectError(error.NoEditor, resolve(a, io, &map, null));
    try testing.expectError(error.NoEditor, resolve(a, io, &map, "   "));
}

test "editores que nao seguram o terminal sao recusados" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var map = try mapWith(testing.allocator, &.{});
    defer map.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.NotForeground, resolve(a, io, &map, "gvim"));
    try testing.expectError(error.NotForeground, resolve(a, io, &map, "/usr/bin/nvim-qt"));
    try testing.expectError(error.NotForeground, resolve(a, io, &map, "code"));
    try testing.expectError(error.NotForeground, resolve(a, io, &map, "subl"));
    _ = try resolve(a, io, &map, "subl -w");
    _ = try resolve(a, io, &map, "vim");
    _ = try resolve(a, io, &map, "vi");
    _ = try resolve(a, io, &map, "nvim");
    _ = try resolve(a, io, &map, "nano");
    _ = try resolve(a, io, &map, "hx");
}

test "which localiza binarios no PATH e caminhos diretos" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "fzf", .data = "" });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", a);

    var map = try mapWith(testing.allocator, &.{
        .{ "PATH", tmp_path },
    });
    defer map.deinit();

    const fzf_cand = which(a, io, &map, "fzf");
    try testing.expect(fzf_cand != null);
    try testing.expect(std.mem.endsWith(u8, fzf_cand.?, "fzf"));
}
