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

test "--client aceita reload e outros comandos" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cmd = try parse(a, &.{ "lst-f", "--client", "reload" });
    try testing.expect(cmd == .client);
    try testing.expectEqualStrings("reload", cmd.client);
}

test "flags de tema (--light, --dark, --theme)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqual(cli.ThemePreference.auto, (try parse(a, &.{"lst-f"})).browse.theme);
    try testing.expectEqual(cli.ThemePreference.light, (try parse(a, &.{ "lst-f", "--light" })).browse.theme);
    try testing.expectEqual(cli.ThemePreference.dark, (try parse(a, &.{ "lst-f", "--dark" })).browse.theme);
    try testing.expectEqual(cli.ThemePreference.light, (try parse(a, &.{ "lst-f", "--theme", "light" })).browse.theme);
    try testing.expectEqual(cli.ThemePreference.dark, (try parse(a, &.{ "lst-f", "--theme", "dark" })).browse.theme);
    try testing.expectEqual(cli.ThemePreference.auto, (try parse(a, &.{ "lst-f", "--theme", "auto" })).browse.theme);

    try testing.expectError(error.MissingValue, parse(a, &.{ "lst-f", "--theme" }));
    try testing.expectError(error.BadValue, parse(a, &.{ "lst-f", "--theme", "invalido" }));
}

test "flag --lang aceita auto, en, pt e rejeita invalidos" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const i18n = @import("lst_f").i18n;

    try testing.expectEqual(@as(?i18n.Lang, null), (try parse(a, &.{"lst-f"})).browse.lang);
    try testing.expectEqual(@as(?i18n.Lang, .en), (try parse(a, &.{ "lst-f", "--lang", "en" })).browse.lang);
    try testing.expectEqual(@as(?i18n.Lang, .pt), (try parse(a, &.{ "lst-f", "--lang", "pt" })).browse.lang);
    try testing.expectEqual(@as(?i18n.Lang, .pt), (try parse(a, &.{ "lst-f", "--lang", "pt_BR" })).browse.lang);
    try testing.expectEqual(@as(?i18n.Lang, null), (try parse(a, &.{ "lst-f", "--lang", "auto" })).browse.lang);

    try testing.expectError(error.MissingValue, parse(a, &.{ "lst-f", "--lang" }));
    try testing.expectError(error.BadValue, parse(a, &.{ "lst-f", "--lang", "fr" }));
}

test "flags novas (--no-icons, --cwd-file, --exclude) e helpers (abbreviateHome, matchesFilter)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Padrao de icones e ligado; --no-icons desliga.
    try testing.expect((try parse(a, &.{"lst-f"})).browse.options.icons);
    const b = (try parse(a, &.{ "lst-f", "--no-icons", "--cwd-file", "/tmp/cwd", "--exclude", ".git", "--exclude", "dist" })).browse;
    try testing.expect(!b.options.icons);
    try testing.expectEqualStrings("/tmp/cwd", b.cwd_file.?);
    try testing.expectEqual(@as(usize, 2), b.options.exclude.len);

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/spock");
    try testing.expectEqualStrings("~", cli.abbreviateHome(a, &env, "/home/spock"));
    try testing.expectEqualStrings("~/Devel/lst-f", cli.abbreviateHome(a, &env, "/home/spock/Devel/lst-f"));
    try testing.expectEqualStrings("/home/spock2/x", cli.abbreviateHome(a, &env, "/home/spock2/x"));

    try testing.expect(cli.matchesFilter("*.log", "app.LOG"));
    try testing.expect(!cli.matchesFilter("*.log", "app.txt"));
    try testing.expect(cli.matchesFilter("plan", "src_plan_test.zig"));
    try testing.expect(!cli.matchesFilter("plan", "fsops.zig"));
}

test "hasOtherPendingEdits distingue dd de movimento de outras edicoes na origem" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const plan = @import("lst_f").plan;

    const originals = [_]plan.Original{
        .{ .id = 10, .path = "a.mp4", .kind = .file },
        .{ .id = 11, .path = "b.mp4", .kind = .file },
        .{ .id = 12, .path = "c.mp4", .kind = .file },
    };

    var moved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    try moved.put(a, 11, {});

    // Unica edicao na origem foi o `dd` do arquivo movido (mesmo reordenado).
    try testing.expect(!try cli.hasOtherPendingEdits(a, &originals, .{
        .edits = &.{
            .{ .id = 12, .path = "c.mp4", .line = 1 },
            .{ .id = 10, .path = "a.mp4", .line = 2 },
        },
        .creates = &.{},
        .directive = null,
    }, &moved));

    // Rename pendente alem do movimento -> nao pode sobrescrever o buffer.
    try testing.expect(try cli.hasOtherPendingEdits(a, &originals, .{
        .edits = &.{
            .{ .id = 10, .path = "a-novo.mp4", .line = 1 },
            .{ .id = 12, .path = "c.mp4", .line = 2 },
        },
        .creates = &.{},
        .directive = null,
    }, &moved));

    // Outro `dd` pendente alem do movimento -> nao pode sobrescrever o buffer.
    try testing.expect(try cli.hasOtherPendingEdits(a, &originals, .{
        .edits = &.{
            .{ .id = 10, .path = "a.mp4", .line = 1 },
        },
        .creates = &.{},
        .directive = null,
    }, &moved));

    // Criacao pendente alem do movimento -> nao pode sobrescrever o buffer.
    try testing.expect(try cli.hasOtherPendingEdits(a, &originals, .{
        .edits = &.{
            .{ .id = 10, .path = "a.mp4", .line = 1 },
            .{ .id = 12, .path = "c.mp4", .line = 2 },
        },
        .creates = &.{.{ .path = "novo.txt", .kind = .file, .line = 3 }},
        .directive = null,
    }, &moved));

    // Copia (`yy`+`p`) pendente alem do movimento -> nao pode sobrescrever o buffer.
    try testing.expect(try cli.hasOtherPendingEdits(a, &originals, .{
        .edits = &.{
            .{ .id = 10, .path = "a.mp4", .line = 1 },
            .{ .id = 10, .path = "a.mp4", .line = 2 },
            .{ .id = 12, .path = "c.mp4", .line = 3 },
        },
        .creates = &.{},
        .directive = null,
    }, &moved));

    // ID estrangeiro colado na origem -> nao pode sobrescrever o buffer.
    try testing.expect(try cli.hasOtherPendingEdits(a, &originals, .{
        .edits = &.{
            .{ .id = 10, .path = "a.mp4", .line = 1 },
            .{ .id = 12, .path = "c.mp4", .line = 2 },
            .{ .id = 99, .path = "outro.mp4", .line = 3 },
        },
        .creates = &.{},
        .directive = null,
    }, &moved));

    // pruneMovedEntries remove apenas os IDs movidos.
    const pruned = try cli.pruneMovedEntries(a, &originals, &moved);
    try testing.expectEqual(@as(usize, 2), pruned.len);
    try testing.expectEqual(@as(u32, 10), pruned[0].id);
    try testing.expectEqual(@as(u32, 12), pruned[1].id);
}
