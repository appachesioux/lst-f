const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const cli = @import("lst_f").cli;
const parseArgs = cli.parseArgs;
const Command = cli.Command;

fn parse(arena: Allocator, args: []const [:0]const u8) !Command {
    return parseArgs(arena, args, true);
}

test "parsing de argumentos" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expect(try parse(a, &.{"lst-f"}) == .browse);
    try testing.expectEqualStrings(".", (try parse(a, &.{"lst-f"})).browse.dir);
    try testing.expectEqualStrings("/tmp", (try parse(a, &.{ "lst-f", "/tmp" })).browse.dir);
    try testing.expect(try parse(a, &.{ "lst-f", "--help" }) == .help);
    try testing.expect(try parse(a, &.{ "lst-f", "-V" }) == .version);
    try testing.expectEqual(
        @as(u32, 12),
        (try parse(a, &.{ "lst-f", "--preview-index", "12" })).preview_index,
    );

    const with_opts = (try parse(a, &.{ "lst-f", "--icons", "--no-color", "--max-depth", "3", "sub" })).browse;
    try testing.expect(with_opts.options.icons);
    try testing.expect(!with_opts.options.color);
    try testing.expectEqual(@as(u16, 3), with_opts.options.max_depth);
    try testing.expectEqualStrings("sub", with_opts.dir);

    try testing.expectError(error.UnknownOption, parse(a, &.{ "lst-f", "--nao-existe" }));
    try testing.expectError(error.MissingValue, parse(a, &.{ "lst-f", "--editor" }));
    try testing.expectError(error.BadValue, parse(a, &.{ "lst-f", "--max-depth", "x" }));
    try testing.expectError(error.TooManyPaths, parse(a, &.{ "lst-f", "a", "b" }));
}

test "--find aceita termo opcional" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("plan", (try parse(a, &.{ "lst-f", "--find", "plan" })).browse.find.?);
    try testing.expectEqualStrings("", (try parse(a, &.{ "lst-f", "--find" })).browse.find.?);
    // Sem termo, mas com diretorio: o caminho nao pode ser engolido como termo.
    const with_dir = (try parse(a, &.{ "lst-f", "--find", "termo", "/tmp" })).browse;
    try testing.expectEqualStrings("termo", with_dir.find.?);
    try testing.expectEqualStrings("/tmp", with_dir.dir);
}

test "recursivo nao e flag de linha de comando" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    // A busca na arvore e a diretiva `:find`, escrita no buffer. Exigir decidir
    // antes de abrir seria pior: o que se quer so aparece navegando.
    try testing.expectError(error.UnknownOption, parse(arena_state.allocator(), &.{ "lst-f", "--recursive" }));
}

test "flags de arquivos ocultos (-a, --all, --hidden, --no-hidden)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expect(!((try parse(a, &.{"lst-f"})).browse.options.show_hidden));
    try testing.expect((try parse(a, &.{ "lst-f", "-a" })).browse.options.show_hidden);
    try testing.expect((try parse(a, &.{ "lst-f", "--all" })).browse.options.show_hidden);
    try testing.expect((try parse(a, &.{ "lst-f", "--hidden" })).browse.options.show_hidden);
    try testing.expect(!((try parse(a, &.{ "lst-f", "-a", "--no-hidden" })).browse.options.show_hidden));
}
