//! Internationalization (i18n): English is the primary/default language,
//! with Portuguese activated automatically from the OS locale or via
//! `LST_F_LANG` / `--lang`.

const std = @import("std");

pub const env_lang = "LST_F_LANG";

pub const Lang = enum {
    en,
    pt,

    pub fn code(self: Lang) []const u8 {
        return switch (self) {
            .en => "en",
            .pt => "pt",
        };
    }

    /// Parses an explicit language specification (`en`, `pt`, `pt_BR`, `en-US`, etc.).
    /// Returns `null` for empty or unrecognized values.
    pub fn parse(raw: []const u8) ?Lang {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        if (matchesPrefix(trimmed, "pt")) return .pt;
        if (matchesPrefix(trimmed, "en")) return .en;
        return null;
    }
};

fn matchesPrefix(locale: []const u8, lang: []const u8) bool {
    if (locale.len < lang.len) return false;
    if (!std.ascii.eqlIgnoreCase(locale[0..lang.len], lang)) return false;
    if (locale.len == lang.len) return true;
    const next = locale[lang.len];
    return next == '_' or next == '-' or next == '.' or next == '@';
}

fn isCOrPosix(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "C") or std.ascii.eqlIgnoreCase(trimmed, "POSIX")) return true;
    if (trimmed.len > 2 and (trimmed[0] == 'C' or trimmed[0] == 'c') and (trimmed[1] == '.' or trimmed[1] == '@')) return true;
    return false;
}

fn fromLocale(raw: []const u8) Lang {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or isCOrPosix(trimmed)) return .en;
    return if (matchesPrefix(trimmed, "pt")) .pt else .en;
}

/// Detects the active language from environment variables:
/// 1. `LST_F_LANG` (explicit override: `en`, `pt`, or `auto`)
/// 2. `LC_ALL` (POSIX highest-priority locale override)
/// 3. `LC_MESSAGES`
/// 4. `LANGUAGE` (GNU colon-separated preference list)
/// 5. `LANG`
/// Defaults to `.en` when unset or any other locale.
pub fn detect(environ: *const std.process.Environ.Map) Lang {
    if (environ.get(env_lang)) |val| {
        const trimmed = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed.len > 0 and !std.ascii.eqlIgnoreCase(trimmed, "auto")) {
            return fromLocale(trimmed);
        }
    }
    if (environ.get("LC_ALL")) |val| {
        const trimmed = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed.len > 0) return fromLocale(trimmed);
    }
    if (environ.get("LC_MESSAGES")) |val| {
        const trimmed = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed.len > 0) return fromLocale(trimmed);
    }
    if (environ.get("LANGUAGE")) |val| {
        var it = std.mem.splitScalar(u8, val, ':');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len > 0) return fromLocale(trimmed);
        }
    }
    if (environ.get("LANG")) |val| {
        const trimmed = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed.len > 0) return fromLocale(trimmed);
    }
    return .en;
}

/// Returns the English or Portuguese string according to `lang`.
pub inline fn tr(lang: Lang, en: []const u8, pt: []const u8) []const u8 {
    return switch (lang) {
        .en => en,
        .pt => pt,
    };
}

/// Translates canonical English `fsops` failure phases for display.
pub fn fsPhase(lang: Lang, phase: []const u8) []const u8 {
    if (lang == .en) return phase;
    if (std.mem.eql(u8, phase, "remove")) return "remover";
    if (std.mem.eql(u8, phase, "create directory")) return "criar diretório";
    if (std.mem.eql(u8, phase, "rename")) return "renomear";
    if (std.mem.eql(u8, phase, "create symlink")) return "criar symlink";
    if (std.mem.eql(u8, phase, "create hardlink")) return "criar hardlink";
    if (std.mem.eql(u8, phase, "create")) return "criar";
    if (std.mem.eql(u8, phase, "move")) return "mover";
    if (std.mem.eql(u8, phase, "copy")) return "copiar";
    if (std.mem.eql(u8, phase, "remove move source")) return "remover a origem do movimento";
    return phase;
}
