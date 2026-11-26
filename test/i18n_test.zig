const std = @import("std");
const testing = std.testing;

const lst_f = @import("lst_f");
const i18n = lst_f.i18n;
const cli = lst_f.cli;
const plan = lst_f.plan;
const preview = lst_f.preview;

test "i18n.detect defaults to English when unset or non-Portuguese" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try testing.expectEqual(i18n.Lang.en, i18n.detect(&env));

    try env.put("LANG", "en_US.UTF-8");
    try testing.expectEqual(i18n.Lang.en, i18n.detect(&env));

    try env.put("LANG", "es_ES.UTF-8");
    try testing.expectEqual(i18n.Lang.en, i18n.detect(&env));

    try env.put("LANG", "C.UTF-8");
    try testing.expectEqual(i18n.Lang.en, i18n.detect(&env));
}

test "i18n.detect activates Portuguese from OS locale variables" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try env.put("LANG", "pt_BR.UTF-8");
    try testing.expectEqual(i18n.Lang.pt, i18n.detect(&env));

    try env.put("LANG", "pt_PT");
    try testing.expectEqual(i18n.Lang.pt, i18n.detect(&env));

    // LC_ALL=C overrides LANG=pt_PT
    try env.put("LC_ALL", "C");
    try testing.expectEqual(i18n.Lang.en, i18n.detect(&env));

    // LC_ALL=pt_BR overrides everything else in POSIX
    try env.put("LC_ALL", "pt_BR.UTF-8");
    try testing.expectEqual(i18n.Lang.pt, i18n.detect(&env));
}

test "i18n.detect respects LC_MESSAGES, LANGUAGE, and LST_F_LANG precedence" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try env.put("LANG", "en_US.UTF-8");
    try env.put("LANGUAGE", "pt_BR:pt:en");
    try testing.expectEqual(i18n.Lang.pt, i18n.detect(&env));

    try env.put("LC_MESSAGES", "en_GB.UTF-8");
    try testing.expectEqual(i18n.Lang.en, i18n.detect(&env));

    // Explicit LST_F_LANG overrides OS locale
    try env.put("LST_F_LANG", "pt");
    try testing.expectEqual(i18n.Lang.pt, i18n.detect(&env));

    try env.put("LST_F_LANG", "en");
    try env.put("LC_ALL", "pt_BR.UTF-8");
    try testing.expectEqual(i18n.Lang.en, i18n.detect(&env));

    // LST_F_LANG=auto falls back to OS locale
    try env.put("LST_F_LANG", "auto");
    try testing.expectEqual(i18n.Lang.pt, i18n.detect(&env));
}

test "cli.printHelp renders English by default and Portuguese when requested" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var en_out: std.Io.Writer.Allocating = .init(a);
    try cli.printHelp(&en_out.writer, .en);
    try testing.expect(std.mem.indexOf(u8, en_out.written(), "usage: lst-f [options] [directory]") != null);
    try testing.expect(std.mem.indexOf(u8, en_out.written(), "--lang <lang>") != null);

    var pt_out: std.Io.Writer.Allocating = .init(a);
    try cli.printHelp(&pt_out.writer, .pt);
    try testing.expect(std.mem.indexOf(u8, pt_out.written(), "uso: lst-f [opções] [diretório]") != null);
    try testing.expect(std.mem.indexOf(u8, pt_out.written(), "--lang <idioma>") != null);
}

test "plan.Problem.describeLang outputs English and Portuguese" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const p: plan.Problem = .{ .create_empty_path = .{ .line = 7 } };

    var en_out: std.Io.Writer.Allocating = .init(a);
    try p.describeLang(&en_out.writer, .en);
    try testing.expectEqualStrings("line 7: empty name", en_out.written());

    var pt_out: std.Io.Writer.Allocating = .init(a);
    try p.describeLang(&pt_out.writer, .pt);
    try testing.expectEqualStrings("linha 7: nome vazio", pt_out.written());
}
