const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const session = @import("lst_f").session;
const History = session.History;

test "historico anda para tras e para frente" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h: History = .{};
    try h.push(arena, "/a");
    try h.push(arena, "/b");
    try h.push(arena, "/c");

    try testing.expectEqualStrings("/b", h.back().?);
    try testing.expectEqualStrings("/a", h.back().?);
    try testing.expectEqual(@as(?[]const u8, null), h.back());
    try testing.expectEqualStrings("/b", h.forward().?);
    try testing.expectEqualStrings("/c", h.forward().?);
    try testing.expectEqual(@as(?[]const u8, null), h.forward());
}

test "entrar em diretorio novo descarta o caminho a frente" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h: History = .{};
    try h.push(arena, "/a");
    try h.push(arena, "/b");
    try h.push(arena, "/c");
    _ = h.back();
    _ = h.back();
    try h.push(arena, "/d");

    try testing.expectEqual(@as(usize, 2), h.items.items.len);
    try testing.expectEqual(@as(?[]const u8, null), h.forward());
    try testing.expectEqualStrings("/a", h.back().?);
}

test "ficar no mesmo diretorio nao empilha" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h: History = .{};
    try h.push(arena, "/a");
    try h.push(arena, "/a");
    try h.push(arena, "/b");
    _ = h.back();
    // Um `:refresh` no meio do historico nao pode virar uma ida nova.
    try h.push(arena, "/a");
    try testing.expectEqual(@as(usize, 2), h.items.items.len);
    try testing.expectEqualStrings("/b", h.forward().?);
}
