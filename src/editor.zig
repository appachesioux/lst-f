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

    pub fn isVimOrNvim(e: Editor) bool {
        const base = e.name();
        return std.mem.eql(u8, base, "vim") or
            std.mem.eql(u8, base, "nvim") or
            std.mem.endsWith(u8, base, "vim") or
            std.mem.endsWith(u8, base, "nvim");
    }
};

/// Editores que nao seguram o terminal. Alguns aceitam uma flag de espera;
/// nesse caso a flag e obrigatoria.
const gui_always = [_][]const u8{ "gvim", "nvim-qt", "mvim", "gedit", "kate", "kwrite", "geany" };
const gui_with_wait = [_][]const u8{ "code", "code-insiders", "codium", "vscodium", "subl", "sublime_text" };
const wait_flags = [_][]const u8{ "--wait", "-w" };

/// Ordem de resolucao:
/// 1. Opcao explicita (--editor <cmd>);
/// 2. Busca no PATH somente por `vim`. Variaveis como $VISUAL e $EDITOR
///    sao ignoradas para garantir uma tela previsivel. O Neovim continua
///    disponivel por `--editor nvim`, mas nunca e escolhido automaticamente.
pub fn resolve(
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    explicit: ?[]const u8,
) ResolveError!Editor {
    const spec = blk: {
        if (explicit) |e| break :blk e;
        if (which(arena, io, environ, "vim") != null) break :blk "vim";
        return error.NoEditor;
    };

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

pub const Background = enum {
    light,
    dark,
};

pub fn parseHexComponent(s: []const u8) ?u32 {
    const val = std.fmt.parseInt(u32, s, 16) catch return null;
    return switch (s.len) {
        1 => val * 4369,
        2 => val * 257,
        4 => val,
        else => null,
    };
}

pub fn parseOsc11Response(resp: []const u8) ?Background {
    const prefix = "rgb:";
    const idx = std.mem.indexOf(u8, resp, prefix) orelse return null;
    const body = resp[idx + prefix.len ..];
    var it = std.mem.tokenizeScalar(u8, body, '/');
    const r_str = it.next() orelse return null;
    const g_str = it.next() orelse return null;
    const rest = it.next() orelse return null;
    var b_len: usize = 0;
    while (b_len < rest.len and rest[b_len] != 0x1b and rest[b_len] != 0x07 and rest[b_len] != '\r' and rest[b_len] != '\n') : (b_len += 1) {}
    const b_str = rest[0..b_len];

    const r = parseHexComponent(r_str) orelse return null;
    const g = parseHexComponent(g_str) orelse return null;
    const b = parseHexComponent(b_str) orelse return null;

    const lum = (299 * r + 587 * g + 114 * b) / 1000;
    return if (lum > 32767) .light else .dark;
}

pub fn parseColorFgBg(cfg: []const u8) ?Background {
    const trimmed = std.mem.trim(u8, cfg, " \t\r\n");
    const last_semi = std.mem.lastIndexOfScalar(u8, trimmed, ';') orelse return null;
    const bg_str = trimmed[last_semi + 1 ..];
    const bg_num = std.fmt.parseInt(u8, bg_str, 10) catch return null;
    return switch (bg_num) {
        0...6, 8 => .dark,
        7, 9...15 => .light,
        else => null,
    };
}

pub fn queryOsc11(io: Io) ?Background {
    const file = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch return null;
    defer file.close(io);
    const fd = file.handle;

    const orig = std.posix.tcgetattr(fd) catch return null;
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    std.posix.tcsetattr(fd, .NOW, raw) catch return null;
    defer std.posix.tcsetattr(fd, .NOW, orig) catch {};

    const query = "\x1b]11;?\x1b\\";
    var written: usize = 0;
    while (written < query.len) {
        const w = std.os.linux.write(fd, query[written..].ptr, query.len - written);
        if (std.os.linux.errno(w) == .INTR) continue;
        if (w <= 0) return null;
        written += @intCast(w);
    }

    var buf: [128]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const r = std.os.linux.read(fd, buf[total..].ptr, buf.len - total);
        if (std.os.linux.errno(r) == .INTR) continue;
        if (r <= 0) break;
        total += @intCast(r);
        if (total >= 2 and buf[total - 2] == 0x1b and buf[total - 1] == '\\') break;
        if (total >= 1 and buf[total - 1] == 0x07) break;
    }

    if (total == 0) return null;
    return parseOsc11Response(buf[0..total]);
}

/// Deteccao do tema do terminal (nunca do desktop/KDE, ja que o terminal
/// pode ser claro enquanto o ambiente e escuro).
pub fn detectTerminalBackground(io: Io, environ: *const std.process.Environ.Map) ?Background {
    if (environ.get("LSTF_THEME")) |val| {
        if (std.ascii.eqlIgnoreCase(val, "light")) return .light;
        if (std.ascii.eqlIgnoreCase(val, "dark")) return .dark;
    }
    if (environ.get("LSTF_BACKGROUND")) |val| {
        if (std.ascii.eqlIgnoreCase(val, "light")) return .light;
        if (std.ascii.eqlIgnoreCase(val, "dark")) return .dark;
    }
    if (environ.get("COLORFGBG")) |cfg| {
        if (parseColorFgBg(cfg)) |bg| return bg;
    }
    return queryOsc11(io);
}

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
    helper_script: ?[]const u8,
) !RunResult {
    var child = try spawn(arena, io, e, environ, path, cwd, helper_script, null);
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| if (code == 0) .saved else .aborted,
        else => .aborted,
    };
}

/// Variante de `run()` sem esperar: quem colhe o processo e o chamador,
/// servindo requisicoes de navegacao enquanto a sessao vive.
pub fn spawn(
    arena: Allocator,
    io: Io,
    e: Editor,
    environ: *const std.process.Environ.Map,
    path: []const u8,
    cwd: []const u8,
    helper_script: ?[]const u8,
    background: ?Background,
) !std.process.Child {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, e.argv);
    // O buffer do lst-f e uma tela controlada pela aplicacao. Iniciar Vim/Neovim
    // sem configuracao pessoal impede temas e plugins de restaurarem statusline,
    // numeros ou outras opcoes depois que o helper termina de configurar a tela.
    // Arquivos abertos pela diretiva :open seguem por outro fluxo e continuam
    // usando a configuracao normal do usuario.
    if (helper_script != null and e.isVimOrNvim()) {
        // `-c` roda tarde demais para a mensagem "arquivo, N linhas". `--cmd`
        // e avaliado antes de o buffer ser lido, entao a linha de comando fica
        // reservada apenas para mensagens que o usuario realmente provocar.
        try argv.appendSlice(arena, &.{ "--cmd", "set shortmess+=F" });
        // Servidor com locale C (SSH sem AcceptEnv LANG) deixa o Vim em
        // `encoding=latin1`: os tres bytes do divisor `│` da grade vao para a
        // tela soltos e viram `◆~T~B`. Tambem precisa ser `--cmd`: trocar
        // `encoding` depois que o buffer foi lido nao reconverte o que ja
        // entrou. Vale so para a tela do lst-f, que e sempre UTF-8; arquivo
        // aberto pela diretiva `:open` segue com a deteccao normal do usuario.
        try argv.appendSlice(arena, &.{ "--cmd", "set encoding=utf-8" });
        if (background) |bg| {
            switch (bg) {
                .light => try argv.appendSlice(arena, &.{ "--cmd", "set background=light" }),
                .dark => try argv.appendSlice(arena, &.{ "--cmd", "set background=dark" }),
            }
        }
        if (std.mem.indexOf(u8, e.name(), "nvim") != null) {
            try argv.append(arena, "--clean");
        } else {
            try argv.appendSlice(arena, &.{ "-u", "NONE", "-U", "NONE", "-i", "NONE", "--noplugin" });
        }
    }
    if (helper_script) |script| {
        if (e.isVimOrNvim()) {
            try argv.append(arena, "-c");
            try argv.append(arena, try std.fmt.allocPrint(arena, "source {s}", .{script}));
        }
    }
    try argv.append(arena, path);

    return std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = environ,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

pub fn selfPath(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) ![]const u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().readLink(io, "/proc/self/exe", &buf)) |n| {
        return arena.dupe(u8, buf[0..n]);
    } else |_| {}
    return whichPathOnly(arena, io, environ, "lst-f") orelse "lst-f";
}

pub fn selfDir(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) ?[]const u8 {
    const p = selfPath(arena, io, environ) catch return null;
    const dir = std.fs.path.dirname(p) orelse return null;
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return null;
    return dir;
}

pub fn whichPathOnly(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
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

/// Localiza um executavel. Ordem de busca:
/// 1. Caminho com barra (direto no disco);
/// 2. Ao lado do proprio binario lst-f (modo bundle/portatil);
/// 3. Variavel de ambiente PATH.
pub fn which(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        Io.Dir.cwd().access(io, name, .{}) catch return null;
        return name;
    }
    if (selfDir(arena, io, environ)) |dir| {
        if (std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name })) |candidate| {
            if (Io.Dir.cwd().access(io, candidate, .{})) |_| {
                return candidate;
            } else |_| {}
        } else |_| {}
    }
    return whichPathOnly(arena, io, environ, name);
}
