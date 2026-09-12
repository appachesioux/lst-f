//! Parsing de argumentos e composicao do fluxo.
//!
//! A tela e o buffer do editor. O `lst-f` gera o buffer, abre o editor do
//! usuario, le de volta o que ele salvou e age: renomeia, move, remove, ou
//! executa a diretiva de navegacao que ele escreveu. O `fzf` entra so quando
//! chamado, como buscador fuzzy na arvore.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const plan = @import("plan.zig");
const explorer = @import("explorer.zig");
const fsops = @import("fsops.zig");
const fzf = @import("fzf.zig");
const editor_mod = @import("editor.zig");
const preview = @import("preview.zig");
const session = @import("session.zig");

const linux = std.os.linux;

/// Caminho a entrar no pedido `enter` de uma sessao viva. Vai por ambiente e
/// nao por argv: caminho de arquivo e dado hostil para interpolar em shell.
pub const live_env_arg = "LST_F_LIVE_ARG";

/// Diretorio do buffer que faz o pedido. Mesmo motivo de `live_env_arg`: e um
/// caminho, entao nao passa por argv. E o que permite ao pai saber em qual
/// janela a navegacao aconteceu quando ha mais de um buffer de diretorio.
pub const live_env_dir = "LST_F_LIVE_DIR";

pub const Command = union(enum) {
    browse: Browse,
    preview_index: u32,
    /// Pedido de navegacao de uma sessao viva (`lst-f --client up`).
    client: []const u8,
    help,
    version,
};

pub const ThemePreference = enum {
    auto,
    light,
    dark,
};

pub const Browse = struct {
    dir: []const u8 = ".",
    editor: ?[]const u8 = null,
    /// Abre direto no buscador, com o termo ja digitado.
    find: ?[]const u8 = null,
    options: explorer.Options = .{},
    theme: ThemePreference = .auto,
};

pub const ArgError = error{ UnknownOption, MissingValue, BadValue, TooManyPaths };

pub fn parseArgs(arena: Allocator, args: []const [:0]const u8, color_default: bool) ArgError!Command {
    var browse: Browse = .{};
    browse.options.color = color_default;
    var saw_path = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;
        if (std.mem.eql(u8, arg, "--preview-index")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            return .{ .preview_index = std.fmt.parseInt(u32, args[i], 10) catch return error.BadValue };
        }
        if (std.mem.eql(u8, arg, "--client")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            return .{ .client = args[i] };
        }
        if (std.mem.eql(u8, arg, "--hidden") or std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            browse.options.show_hidden = true;
        } else if (std.mem.eql(u8, arg, "--no-hidden")) {
            browse.options.show_hidden = false;
        } else if (std.mem.eql(u8, arg, "--icons")) {
            browse.options.icons = true;
        } else if (std.mem.eql(u8, arg, "--no-icons")) {
            browse.options.icons = false;
        } else if (std.mem.eql(u8, arg, "--color")) {
            browse.options.color = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            browse.options.color = false;
        } else if (std.mem.eql(u8, arg, "--light")) {
            browse.theme = .light;
        } else if (std.mem.eql(u8, arg, "--dark")) {
            browse.theme = .dark;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (std.mem.eql(u8, args[i], "light")) {
                browse.theme = .light;
            } else if (std.mem.eql(u8, args[i], "dark")) {
                browse.theme = .dark;
            } else if (std.mem.eql(u8, args[i], "auto")) {
                browse.theme = .auto;
            } else {
                return error.BadValue;
            }
        } else if (std.mem.eql(u8, arg, "--editor")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            browse.editor = args[i];
        } else if (std.mem.eql(u8, arg, "--find") or std.mem.eql(u8, arg, "-f")) {
            // O termo e opcional: `--find` sozinho abre o buscador na arvore.
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                browse.find = args[i];
            } else {
                browse.find = "";
            }
        } else if (std.mem.eql(u8, arg, "--max-depth")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            browse.options.max_depth = std.fmt.parseInt(u16, args[i], 10) catch return error.BadValue;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            return error.UnknownOption;
        } else {
            if (saw_path) return error.TooManyPaths;
            browse.dir = arena.dupe(u8, arg) catch return error.BadValue;
            saw_path = true;
        }
    }
    return .{ .browse = browse };
}

pub fn printHelp(w: *Io.Writer) !void {
    try w.print(
        \\{s} v{s} -- explora e altera o filesystem no terminal
        \\
        \\uso: lst-f [opcoes] [diretorio]
        \\
        \\A tela e o buffer do seu Vim ou Neovim. Cada linha e uma entrada, com um
        \\ID a esquerda. Edite o caminho para renomear ou mover; apague a linha
        \\para remover. O ID casa a linha com a entrada, entao reordenar, rodar
        \\:sort ou recolar linhas e inofensivo.
        \\
        \\  -a, --all, --hidden  mostra arquivos e diretorios ocultos
        \\  --find [termo]     abre direto no buscador fuzzy da arvore
        \\  --editor <cmd>     editor a usar (padrao: vim; nvim so se explicito)
        \\  --max-depth <n>    profundidade maxima da busca recursiva
        \\  --icons            emite icones na busca
        \\  --no-color         desliga as cores
        \\  --light, --dark    forca tema claro ou escuro (padrao: auto-detectado)
        \\  --theme <modo>     define tema: auto, light ou dark
        \\  -h, --help         esta ajuda
        \\  -V, --version      versao
        \\
        \\diretivas, escritas no proprio buffer:
        \\  :cd <dir>          entra no diretorio (.. sobe)
        \\  :hidden            alterna exibicao de arquivos ocultos
        \\  :find [termo]      busca fuzzy na arvore com o fzf; o que voce marcar
        \\                     vira o conteudo do buffer
        \\  :sh [dir]          abre terminal / shell no diretorio (:shell, :terminal)
        \\  :ln <alvo> [nome]  cria symlink para o alvo (:link, :symlink, :hardlink)
        \\  :undo              desfaz a ultima operacao aplicada nesta sessao
        \\  :quit              sai (salvar sem mudancas tambem sai; :cq aborta)
        \\  .                  alterna exibicao de arquivos ocultos
        \\  F4                 abre terminal / shell no diretorio atual
        \\  Enter              abre o arquivo da linha ou entra no diretorio
        \\  nome -> alvo       em linha nova cria symlink (nome => alvo cria hardlink)
        \\
        \\no buscador:
        \\  Tab                marca / desmarca      Enter  aceita a marcacao
        \\  Ctrl+A             marca / desmarca tudo
        \\  {s}              abre e fecha o preview (comeca fechado)
        \\  {s}                 esta ajuda            Esc    cancela
        \\
        \\Precisa do fzf ({d}.{d}+) e do Vim no PATH (ou --editor <cmd>).
        \\
    , .{
        build_options.app_name,
        build_options.version,
        fzf.Keys.preview,
        fzf.Keys.help_label,
        fzf.min_version.major,
        fzf.min_version.minor,
    });
}

// ---------------------------------------------------------------------------
// Entrada
// ---------------------------------------------------------------------------

pub fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const color_default = environ.get("NO_COLOR") == null;

    if (environ.get("LSTF_TZ_OFFSET")) |tz_str| {
        if (std.fmt.parseInt(i32, tz_str, 10)) |val| {
            explorer.tz_offset_seconds = val * 3600;
        } else |_| {}
    } else {
        if (Io.Dir.openFileAbsolute(io, "/etc/localtime", .{})) |*file| {
            defer file.close(io);
            var buf: [16384]u8 = undefined;
            if (file.readPositionalAll(io, &buf, 0)) |n| {
                const tzif = @import("tzif.zig");
                const ns: i96 = std.Io.Clock.now(.real, io).toNanoseconds();
                const now: i64 = @intCast(@divFloor(ns, std.time.ns_per_s));
                if (tzif.parseTzif(buf[0..n], now)) |offset| {
                    explorer.tz_offset_seconds = offset;
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }

    const cmd = parseArgs(arena, args, color_default) catch |err| {
        try out.print("lst-f: argumentos invalidos ({s})\n\n", .{@errorName(err)});
        try printHelp(out);
        return 2;
    };

    return switch (cmd) {
        .help => blk: {
            try printHelp(out);
            break :blk 0;
        },
        .version => blk: {
            try out.print("{s} v{s}\n", .{ build_options.app_name, build_options.version });
            break :blk 0;
        },
        .preview_index => |index| runPreview(arena, io, out, environ, index),
        .client => |name| runClient(out, environ, name),
        .browse => |b| runSession(arena, io, out, environ, b),
    };
}

/// Preview do buscador, por self-exec. O indice vem do campo 1 do registro e
/// resolve para o caminho pela lista que o processo principal deixou no estado.
fn runPreview(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *const std.process.Environ.Map,
    index: u32,
) !u8 {
    const state = session.State.open(arena, io, environ) catch return 1;
    const base_path = state.readBase(io, arena) catch return 1;
    const list = state.readList(io, arena) catch return 1;
    if (index >= list.len) return 1;

    var base = Io.Dir.cwd().openDir(io, base_path, .{}) catch return 1;
    defer base.close(io);
    try preview.render(arena, io, out, base, list[index]);
    return 0;
}

/// Pedido de navegacao de uma sessao viva. Conecta ao socket do processo pai,
/// envia `cmd\0arg\0dir` e espera o veredito. O argumento opcional (caminho a
/// entrar) e o diretorio do buffer que pede chegam por variavel de ambiente,
/// nunca por argv: caminho de arquivo e dado hostil para interpolar em linha
/// de comando.
///
/// `dir` e o que permite mais de um buffer de diretorio aberto ao mesmo tempo:
/// sem ele o pai nao saberia em qual janela a navegacao aconteceu.
fn runClient(out: *Io.Writer, environ: *std.process.Environ.Map, cmd: []const u8) !u8 {
    const state_path = environ.get(session.env_state) orelse {
        try out.writeAll("lst-f: sem sessao viva\n");
        return 2;
    };
    const arg = environ.get(live_env_arg) orelse "";
    const dir = environ.get(live_env_dir) orelse "";

    var addr: linux.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    const sock_path = std.fmt.bufPrint(&addr.path, "{s}/live.sock", .{state_path}) catch return 2;
    _ = sock_path;

    const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd) != .SUCCESS) return 2;
    const sock: i32 = @intCast(fd);
    defer _ = linux.close(sock);

    if (linux.errno(linux.connect(
        sock,
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.un),
    )) != .SUCCESS) {
        try out.writeAll("lst-f: sessao nao responde\n");
        return 2;
    }

    var payload: [4096]u8 = undefined;
    if (cmd.len + 1 + arg.len + 1 + dir.len > payload.len) return 2;
    var total: usize = 0;
    @memcpy(payload[0..cmd.len], cmd);
    total += cmd.len;
    payload[total] = 0;
    total += 1;
    @memcpy(payload[total..][0..arg.len], arg);
    total += arg.len;
    payload[total] = 0;
    total += 1;
    @memcpy(payload[total..][0..dir.len], dir);
    total += dir.len;
    var sent: usize = 0;
    while (sent < total) {
        const w = linux.write(sock, payload[sent..].ptr, total - sent);
        if (linux.errno(w) != .SUCCESS) return 2;
        sent += w;
    }
    // Metade de escrita fechada: o servidor le ate EOF.
    _ = linux.shutdown(sock, linux.SHUT.WR);

    var reply: [1024]u8 = undefined;
    var got: usize = 0;
    while (got < reply.len) {
        const r = linux.read(sock, reply[got..].ptr, reply.len - got);
        if (linux.errno(r) == .INTR) continue;
        if (r == 0) break; // EOF
        if (linux.errno(r) != .SUCCESS) return 2;
        got += r;
    }
    if (got == 0) return 2;
    if (reply[0] != 'K') {
        try out.print("lst-f: {s}\n", .{reply[1..got]});
        return 1;
    }
    // Sucesso: devolve o caminho do buffer que a janela deve exibir agora. O
    // helper captura pela saida do `system()`; vazio quando o pedido nao
    // trocou de tela (tema, preview).
    const body = std.mem.trim(u8, reply[1..got], "\n");
    if (body.len > 0) try out.print("{s}\n", .{body});
    return 0;
}

// ---------------------------------------------------------------------------
// Sessao
// ---------------------------------------------------------------------------

const AreaRef = struct {
    base: []const u8,
    name: []const u8,
};

const Undo = struct {
    base: []const u8,
    area: ?[]const u8,
    applied: fsops.Applied,
};

/// Um diretorio aberto como buffer. Cada janela do Vim aponta para um View,
/// e o CLI guarda um por diretorio visitado na sessao. E isso que permite
/// dois diretorios lado a lado como mecanica pura do Vim (`:vsplit` +
/// navegar), no modelo do oil.nvim, sem "painel de destino" separado.
const View = struct {
    /// Diretorio absoluto deste buffer. E a ancora de todo caminho relativo
    /// que o usuario ve e edita aqui dentro.
    dir: []const u8,
    /// Arquivo em disco que carrega o conteudo do buffer.
    buffer_path: []const u8,
    /// Listagem corrente.
    entries: []plan.Original = &.{},
    /// Nomes que nao sobrevivem ao round-trip do Vim e por isso sao so leitura.
    unlistable: []const []const u8 = &.{},
    /// Cabecalho do buffer aberto agora. O parser precisa do texto exato para
    /// nao confundir cabecalho com nome de arquivo.
    header_lines: []const []const u8 = &.{},
    /// O buffer no disco ja serve; nao regerar (o usuario tem correcoes a fazer).
    keep_buffer: bool = false,
    /// Area de sessao deste diretorio (remocao e rollback).
    area: ?fsops.Area = null,
    area_name: []const u8 = "",
    /// Diretorios visitados a partir deste buffer, para `:back` e `:forward`.
    history: session.History = .{},
    /// Escopo de um `:find` em vigor neste buffer, para o cabecalho.
    scope: ?[]const u8 = null,
    /// Ultima operacao aplicada a partir deste buffer, para o `:undo`. E do
    /// buffer, nao da sessao: com duas janelas abertas, `:undo` numa delas
    /// desfazendo o que aconteceu na outra seria um efeito invisivel.
    undo: ?Undo = null,
    /// Base dos IDs deste buffer e quantos estao reservados a partir dela.
    /// IDs sao unicos na sessao inteira, nao por buffer: um `yy` numa janela
    /// seguido de `p` na outra nao pode casar com uma entrada de outra pasta.
    /// O numero existiria nos dois buffers e o plano copiaria o arquivo
    /// errado em silencio.
    id_base: u32 = 0,
    id_span: u32 = 0,
};

/// diretorio -> View. Os Views vivem no arena, entao `*View` e estavel.
const ViewRegistry = struct {
    views: std.StringHashMapUnmanaged(*View) = .empty,
    counter: usize = 0,

    pub fn get(self: *const ViewRegistry, dir: []const u8) ?*View {
        return self.views.get(dir);
    }

    /// View de `dir`, criando buffer e registro na primeira vez.
    pub fn getOrCreate(
        self: *ViewRegistry,
        arena: Allocator,
        io: Io,
        state_path: []const u8,
        dir: []const u8,
    ) !*View {
        if (self.views.get(dir)) |v| return v;
        const buffer_path = try std.fmt.allocPrint(arena, "{s}/buffers/{d:0>4}.lstf", .{ state_path, self.counter });
        self.counter += 1;
        const v = try arena.create(View);
        v.* = .{ .dir = dir, .buffer_path = buffer_path };
        try self.views.put(arena, dir, v);
        _ = io;
        return v;
    }

    pub fn iterator(self: *const ViewRegistry) std.StringHashMapUnmanaged(*View).Iterator {
        return self.views.iterator();
    }
};

const Session = struct {
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    tty: ?Tty,
    options: explorer.Options,
    editor_spec: ?[]const u8,
    features: fzf.Features,
    state: session.State,
    pid: std.posix.pid_t,
    helper_path: []const u8,
    /// Identidade exibida na barra permanente do buffer.
    editor_name: []const u8,
    background: ?editor_mod.Background = null,

    /// Buffer em foco: o da janela que fez o ultimo pedido, ou o principal
    /// na volta externa do editor. Todo caminho relativo se resolve contra
    /// `view.dir` — nao existe mais ancora concorrente.
    view: *View,
    /// Todos os diretorios abertos na sessao, um View por diretorio.
    views: ViewRegistry = .{},
    /// Proximo ID livre da sessao. Ver `View.id_base`.
    next_id: u32 = 0,

    /// Aviso de uma operacao concluida, mostrado uma vez no buffer reaberto.
    notice: ?[]const u8 = null,
    /// Buffers de outras janelas que a ultima aplicacao mudou (as pastas de
    /// onde saiu um movimento). Vao na resposta do canal vivo para o helper
    /// recarregar aquelas janelas; so a janela que pediu se recarrega sozinha.
    reload_others: []const []const u8 = &.{},
    /// Areas de sessao abertas, para limpeza no fim e deteccao de orfas.
    areas: std.ArrayList(AreaRef) = .empty,
};

fn runSession(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    opts: Browse,
) !u8 {
    const base = Io.Dir.cwd().realPathFileAlloc(io, opts.dir, arena) catch {
        try out.print("lst-f: nao foi possivel abrir {s}\n", .{opts.dir});
        return 1;
    };

    // O editor e requisito, nao conveniencia: sem ele nao ha tela.
    const initial_editor = editor_mod.resolve(arena, io, environ, opts.editor) catch |err| {
        try explainEditor(out, err);
        return 1;
    };

    const features = fzf.detect(arena, io, environ) catch |err| blk: {
        try warnFzf(out, err);
        break :blk fzf.Features{ .version = .{ .major = 0, .minor = 0 }, .raw = "" };
    };

    const bg: ?editor_mod.Background = switch (opts.theme) {
        .light => .light,
        .dark => .dark,
        .auto => editor_mod.detectTerminalBackground(io, environ),
    };
    if (bg) |b| {
        if (environ.get("COLORFGBG") == null) {
            environ.put("COLORFGBG", switch (b) {
                .light => "0;15",
                .dark => "15;0",
            }) catch {};
        }
    }

    const pid = std.os.linux.getpid();
    var state = try session.State.create(arena, io, environ, pid);
    defer state.destroy(io);

    try environ.put(session.env_state, state.path);
    try environ.put(session.env_self, try editor_mod.selfPath(arena, io, environ));
    // O contrato com o fzf depende de flags exatas, e `FZF_DEFAULT_OPTS` entra
    // antes delas. Uma configuracao pessoal comum como `--preview-window hidden`
    // ja desliga o preview, e um `--bind ...execute(rm -i {})` receberia o
    // registro inteiro no lugar de um caminho.
    try environ.put("FZF_DEFAULT_OPTS", "");
    try environ.put("FZF_DEFAULT_OPTS_FILE", "");

    const helper_path = try std.fmt.allocPrint(arena, "{s}/helper.vim", .{state.path});
    try state.writeHelperScript(io, build_options.app_name, build_options.version);

    // Um arquivo de buffer por diretorio aberto: e o que permite duas
    // janelas com dois diretorios diferentes (Fase 1 da revisao de UX).
    state.dir.createDir(io, "buffers", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    if (bg) |b| {
        state.dir.writeFile(io, .{
            .sub_path = "theme",
            .data = switch (b) {
                .light => "light\n",
                .dark => "dark\n",
            },
        }) catch {};
    }

    var views: ViewRegistry = .{};
    const initial_view = try views.getOrCreate(arena, io, state.path, base);
    try initial_view.history.push(arena, base);

    var s: Session = .{
        .arena = arena,
        .io = io,
        .out = out,
        .environ = environ,
        .tty = Tty.open(arena, io),
        .options = opts.options,
        .editor_spec = opts.editor,
        .editor_name = editorLabel(initial_editor),
        .background = bg,
        .features = features,
        .state = state,
        .pid = pid,
        .helper_path = helper_path,
        .view = initial_view,
        .views = views,
    };
    defer cleanupAreas(&s);

    if (opts.find) |query| {
        if (!try runFind(&s, query)) try loadListing(&s);
    } else {
        try loadListing(&s);
    }

    try loop(&s);
    return 0;
}

fn loop(s: *Session) !void {
    while (true) {
        if (s.state.dir.readFileAlloc(s.io, "theme", s.arena, .limited(32))) |content| {
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "light")) {
                s.background = .light;
            } else if (std.mem.eql(u8, trimmed, "dark")) {
                s.background = .dark;
            }
        } else |_| {}

        if (!s.view.keep_buffer) {
            s.state.clearApproval(s.io);
            try writeBuffer(s);
        }
        s.view.keep_buffer = false;

        const editor = editor_mod.resolve(s.arena, s.io, s.environ, s.editor_spec) catch |err| {
            try explainEditor(s.out, err);
            return;
        };
        const spawned = editor_mod.spawn(
            s.arena,
            s.io,
            editor,
            s.environ,
            s.view.buffer_path,
            s.view.dir,
            s.helper_path,
            s.background,
        ) catch |err| {
            try s.out.print("lst-f: falha ao abrir o editor: {s}\n", .{@errorName(err)});
            return;
        };
        var child = spawned;
        // Sessao viva: navegacao sem fechar o editor (sem flick). Se a
        // infraestrutura de socket nao estiver disponivel, cai para o fluxo
        // antigo: cada diretiva fecha e reabre o editor.
        const served = try serveEditorRound(s, &child);
        const result: editor_mod.RunResult = if (served) |code|
            if (code == 0) .saved else .aborted
        else blk: {
            const term = child.wait(s.io) catch |err| {
                try s.out.print("lst-f: falha ao abrir o editor: {s}\n", .{@errorName(err)});
                return;
            };
            break :blk switch (term) {
                .exited => |code| if (code == 0) .saved else .aborted,
                else => .aborted,
            };
        };
        // Sair com erro (:cq) e o sinal de "nao aplica nada", como no git commit.
        if (result == .aborted) {
            try s.out.writeAll("lst-f: editor saiu com erro; nada foi aplicado.\n");
            return;
        }

        const text = try Io.Dir.cwd().readFileAlloc(
            s.io,
            s.view.buffer_path,
            s.arena,
            .limited(64 * 1024 * 1024),
        );
        const parsed = try plan.parseBuffer(s.arena, text, s.view.header_lines);
        switch (parsed) {
            .invalid => |problems| {
                try reportProblems(s, problems);
                s.view.keep_buffer = true;
                continue;
            },
            .ok => {},
        }
        const document = parsed.ok;

        const built = try buildPlan(s, document);
        switch (built) {
            .invalid => |problems| {
                try reportProblems(s, problems);
                s.view.keep_buffer = true;
                continue;
            },
            .ok => {},
        }

        const collisions = try checkCreatesOnDisk(s, built.ok);
        if (collisions.len > 0) {
            try reportProblems(s, collisions);
            s.view.keep_buffer = true;
            continue;
        }

        var plan_ok = built.ok;
        const copy_resolved = try resolveCopySuffixesOnDisk(s, plan_ok);
        plan_ok = copy_resolved.plan;
        if (copy_resolved.problems.len > 0) {
            try reportProblems(s, copy_resolved.problems);
            s.view.keep_buffer = true;
            continue;
        }

        const changed = !plan_ok.isEmpty();
        if (changed) {
            const approved_in_editor = s.state.takeApproval(s.io);
            if (document.directive) |d| {
                if (d == .quit and !approved_in_editor) {
                    return;
                }
            }
            if (!try confirmAndApply(s, plan_ok, approved_in_editor)) {
                // Se o usuario pediu para sair (:quit), nos DEVEMOS sair,
                // mesmo se a confirmacao foi recusada ou a aplicacao falhou.
                if (document.directive) |d| {
                    if (d == .quit) return;
                }
                // No modo fallback/sem diretiva, se o usuario recusou a confirmacao
                // no prompt do terminal (approved_in_editor == false), ele optou
                // por nao aplicar as mudancas ao fechar o editor.
                if (document.directive == null and !approved_in_editor) {
                    return;
                }
                try loadListing(s);
                continue;
            }
        }

        const directive = document.directive orelse {
            // Nada mudou e nada foi pedido: acabou.
            if (!changed) return;
            try loadListing(s);
            continue;
        };

        switch (directive) {
            .quit => return,
            .refresh => try loadListing(s),
            .undo => try undoLast(s),
            .back => try goBack(s),
            .forward => try goForward(s),
            .cd => |target| try changeDir(s, target),
            .open => |target| try openFileInEditor(s, target),
            .shell => |target| try openShell(s, target),
            .hidden => |opt| {
                if (opt) |val| {
                    s.options.show_hidden = val;
                } else {
                    s.options.show_hidden = !s.options.show_hidden;
                }
                try loadListing(s);
            },
            .find => |query| {
                if (!try runFind(s, query)) try loadListing(s);
            },
            .theme => |opt| {
                const next_bg: editor_mod.Background = if (opt) |val| switch (val) {
                    .light => .light,
                    .dark => .dark,
                } else switch (s.background orelse .dark) {
                    .light => .dark,
                    .dark => .light,
                };
                s.background = next_bg;
                s.state.dir.writeFile(s.io, .{
                    .sub_path = "theme",
                    .data = switch (next_bg) {
                        .light => "light\n",
                        .dark => "dark\n",
                    },
                }) catch {};
                s.environ.put("COLORFGBG", switch (next_bg) {
                    .light => "0;15",
                    .dark => "15;0",
                }) catch {};
                try loadListing(s);
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Sessao viva: navegacao sem reabrir o editor
// ---------------------------------------------------------------------------

/// Serve os pedidos de navegacao (`--client`) enquanto esta rodada do editor
/// vive. Devolve o codigo de saida do editor; `null` quando a infraestrutura
/// de socket nao esta disponivel e o chamador deve apenas esperar o editor
/// sair (fluxo antigo, com reabertura por diretiva).
fn serveEditorRound(s: *Session, child: *std.process.Child) !?u8 {
    var path_buf: [108]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&path_buf, "{s}/live.sock", .{s.state.path}) catch return null;
    var z_buf: [109]u8 = undefined;
    const sock_z = std.fmt.bufPrintZ(&z_buf, "{s}", .{sock_path}) catch unreachable;

    _ = linux.unlink(sock_z);
    const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    const listener: i32 = @intCast(fd);
    defer {
        _ = linux.close(listener);
        _ = linux.unlink(sock_z);
    }

    var addr: linux.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..sock_path.len], sock_path);
    if (linux.errno(linux.bind(
        listener,
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.un),
    )) != .SUCCESS) return null;
    if (linux.errno(linux.listen(listener, 4)) != .SUCCESS) return null;
    // O socket fica sob $TMPDIR, que pode ser compartilhado: sem isso,
    // outro usuario local conectaria e navegaria na sessao alheia.
    _ = linux.fchmodat(linux.AT.FDCWD, sock_z, 0o600);

    while (true) {
        var fds = [_]linux.pollfd{.{ .fd = listener, .events = linux.POLL.IN, .revents = 0 }};
        const prc = linux.poll(&fds, fds.len, 120);
        switch (linux.errno(prc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return null,
        }
        if (prc > 0 and fds[0].revents & linux.POLL.IN != 0) {
            const conn_rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(conn_rc) == .SUCCESS) {
                const conn: i32 = @intCast(conn_rc);
                handleLiveConn(s, conn) catch |err| {
                    var reply_buf: [192]u8 = undefined;
                    const reply = std.fmt.bufPrint(&reply_buf, "Efalha interna na sessao viva ({s})", .{@errorName(err)}) catch "Efalha interna na sessao viva";
                    _ = linux.write(conn, reply.ptr, reply.len);
                };
                _ = linux.close(conn);
            }
        }

        var status: u32 = 0;
        const wrc = linux.wait4(child.id.?, &status, linux.W.NOHANG, null);
        switch (linux.errno(wrc)) {
            .SUCCESS => if (wrc != 0) {
                // Processo colhido: decodifica o desfecho.
                if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
                return 1;
            },
            .CHILD => return 1,
            .INTR => continue,
            else => return null,
        }
    }
}

/// Um pedido: `cmd` seguido de NUL e argumento opcional; o cliente fecha a
/// metade de escrita e o servidor responde `K` ou `E<mensagem>`.
fn handleLiveConn(s: *Session, conn: i32) !void {
    var req: [8192]u8 = undefined;
    var got: usize = 0;
    while (got < req.len) {
        const r = linux.read(conn, req[got..].ptr, req.len - got);
        switch (linux.errno(r)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }
        if (r == 0) break;
        got += r;
    }
    const payload = req[0..got];
    var fields = std.mem.splitScalar(u8, payload, 0);
    const cmd = fields.next() orelse payload;
    const arg = fields.next() orelse "";
    const req_dir = fields.next() orelse "";

    // O pedido vem de uma janela especifica: o foco passa a ser o View dela.
    // Sem isso, navegar numa janela reescreveria o buffer da outra.
    if (req_dir.len > 0) {
        if (s.views.get(req_dir)) |v| {
            s.view = v;
        } else if (std.fs.path.isAbsolute(req_dir)) {
            s.view = try s.views.getOrCreate(s.arena, s.io, s.state.path, req_dir);
        }
    }

    var ok = false;
    var rewrote_buffer = false;
    var response: ?[]const u8 = null;
    s.reload_others = &.{};
    if (std.mem.eql(u8, cmd, "up")) {
        writeCursorNameHint(s);
        ok = enterDirQuiet(s, "..");
    } else if (std.mem.eql(u8, cmd, "home")) {
        ok = enterDirQuiet(s, "~");
    } else if (std.mem.eql(u8, cmd, "back")) {
        const before = s.view.dir;
        try goBack(s);
        ok = !std.mem.eql(u8, before, s.view.dir) or s.notice == null;
    } else if (std.mem.eql(u8, cmd, "forward")) {
        const before = s.view.dir;
        try goForward(s);
        ok = !std.mem.eql(u8, before, s.view.dir) or s.notice == null;
    } else if (std.mem.eql(u8, cmd, "hidden")) {
        s.options.show_hidden = !s.options.show_hidden;
        loadListing(s) catch {
            s.notice = "nao consegui listar o diretorio";
        };
        ok = true;
    } else if (std.mem.eql(u8, cmd, "enter")) {
        // Entrar pousa na primeira entrada: sem dica de cursor.
        s.state.dir.deleteFile(s.io, "cursor_name") catch {};
        ok = enterDirQuiet(s, arg);
    } else if (std.mem.eql(u8, cmd, "reload") or std.mem.eql(u8, cmd, "refresh")) {
        loadListing(s) catch {
            s.notice = "nao consegui listar o diretorio";
        };
        s.notice = "lista atualizada";
        ok = true;
    } else if (std.mem.eql(u8, cmd, "apply")) {
        if (try applySavedBufferLive(s)) |message| {
            response = message;
        } else {
            ok = true;
            rewrote_buffer = true;
        }
    } else if (std.mem.eql(u8, cmd, "preview")) {
        if (try previewProposedBuffer(s)) |message| {
            response = message;
        } else {
            ok = true;
        }
    } else if (std.mem.eql(u8, cmd, "theme")) {
        const next_bg: editor_mod.Background = if (std.mem.eql(u8, arg, "light"))
            .light
        else if (std.mem.eql(u8, arg, "dark"))
            .dark
        else switch (s.background orelse .dark) {
            .light => .dark,
            .dark => .light,
        };
        s.background = next_bg;
        s.state.dir.writeFile(s.io, .{
            .sub_path = "theme",
            .data = switch (next_bg) {
                .light => "light\n",
                .dark => "dark\n",
            },
        }) catch {};
        s.environ.put("COLORFGBG", switch (next_bg) {
            .light => "0;15",
            .dark => "15;0",
        }) catch {};
        ok = true;
    }

    const failure = s.notice;
    // Navegacao sempre produz uma tela nova. O apply ja a escreveu no sucesso
    // e preserva no disco o buffer editado quando precisa devolver um erro.
    if (!rewrote_buffer and
        !std.mem.eql(u8, cmd, "apply") and
        !std.mem.eql(u8, cmd, "preview") and
        !std.mem.eql(u8, cmd, "theme")) try writeBuffer(s);

    if (ok) {
        // Sucesso devolve o caminho do buffer desta janela: navegacao pode ter
        // trocado de View, e o helper precisa saber qual arquivo `:edit`ar. As
        // linhas seguintes, quando ha, sao os buffers de outras janelas que a
        // aplicacao mexeu -- a pasta de onde um movimento saiu.
        var reply: std.ArrayList(u8) = .empty;
        try reply.append(s.arena, 'K');
        try reply.appendSlice(s.arena, s.view.buffer_path);
        for (s.reload_others) |other| {
            try reply.append(s.arena, '\n');
            try reply.appendSlice(s.arena, other);
        }
        _ = linux.write(conn, reply.items.ptr, reply.items.len);
    } else {
        var reply_buf: [512]u8 = undefined;
        const msg = response orelse failure orelse "nao foi possivel";
        const n = @min(msg.len, reply_buf.len - 2);
        reply_buf[0] = 'E';
        @memcpy(reply_buf[1 .. 1 + n], msg[0..n]);
        _ = linux.write(conn, reply_buf[0 .. 1 + n].ptr, 1 + n);
    }
}

/// Aplica um `:w` sem encerrar a instancia corrente do Vim. O proprio helper
/// ja pediu confirmacao e gravou o sinal `approved`; aqui fazemos o mesmo
/// pipeline da volta externa e, no sucesso, deixamos no disco a listagem nova
/// que o editor recarregara com `:edit!`.
fn applySavedBufferLive(s: *Session) !?[]const u8 {
    const text = try Io.Dir.cwd().readFileAlloc(
        s.io,
        s.view.buffer_path,
        s.arena,
        .limited(64 * 1024 * 1024),
    );
    const parsed = try plan.parseBuffer(s.arena, text, s.view.header_lines);
    if (parsed == .invalid) return try describeProblems(s, parsed.invalid);
    const document = parsed.ok;
    if (document.directive == null or document.directive.? != .refresh) {
        return "diretiva requer a volta completa da sessao";
    }

    const built = try buildPlan(s, document);
    if (built == .invalid) return try describeProblems(s, built.invalid);

    const collisions = try checkCreatesOnDisk(s, built.ok);
    if (collisions.len > 0) return try describeProblems(s, collisions);

    const copy_resolved = try resolveCopySuffixesOnDisk(s, built.ok);
    if (copy_resolved.problems.len > 0) return try describeProblems(s, copy_resolved.problems);

    const p = copy_resolved.plan;
    if (!p.isEmpty()) {
        if (!s.state.takeApproval(s.io)) return "alteracoes nao foram confirmadas";
        if (try applyApprovedLive(s, p)) |message| return message;
        s.reload_others = try refreshMovedSources(s, p.copies, try std.fmt.allocPrint(
            s.arena,
            "movido para {s}",
            .{abbreviateHome(s.arena, s.environ, s.view.dir)},
        ));
    }

    try loadListing(s);
    try writeBuffer(s);
    return null;
}

/// Depois de mover entradas de outras pastas para ca, os buffers delas mostram
/// uma linha que nao existe mais (e depois de um `:undo`, o contrario). Relista
/// e regrava cada um, e devolve o caminho dos arquivos para o helper recarregar
/// as janelas que os mostram. O View em foco fica por ultimo, no chamador: e
/// ele quem escreve o estado global que o self-exec de preview do fzf le.
fn refreshMovedSources(s: *Session, copies: []const plan.Copy, note: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const focused = s.view;
    const notice = s.notice;
    defer {
        s.view = focused;
        s.notice = notice;
    }
    for (copies) |c| {
        if (!c.cut) continue;
        const abs = c.from_abs orelse continue;
        const dir = std.fs.path.dirname(abs) orelse continue;
        if ((try seen.getOrPut(s.arena, dir)).found_existing) continue;
        const v = s.views.get(dir) orelse continue;
        s.view = v;
        // O recado da pasta de origem e outro: aqui a linha sumiu, nao chegou.
        s.notice = note;
        loadListing(s) catch continue;
        writeBuffer(s) catch continue;
        try out.append(s.arena, v.buffer_path);
    }
    return out.toOwnedSlice(s.arena);
}

/// Monta o mesmo plano da aplicacao a partir da copia que o helper gravou
/// antes do `:w`, mas nao altera o filesystem. A lista humana vai para um
/// arquivo de estado porque a resposta curta do socket carrega so o veredito.
fn previewProposedBuffer(s: *Session) !?[]const u8 {
    const text = s.state.dir.readFileAlloc(
        s.io,
        "proposal",
        s.arena,
        .limited(64 * 1024 * 1024),
    ) catch return "nao foi possivel ler a proposta do buffer";
    const parsed = try plan.parseBuffer(s.arena, text, s.view.header_lines);
    if (parsed == .invalid) return try describeProblems(s, parsed.invalid);
    const document = parsed.ok;

    const built = try buildPlan(s, document);
    if (built == .invalid) return try describeProblems(s, built.invalid);

    const collisions = try checkCreatesOnDisk(s, built.ok);
    if (collisions.len > 0) return try describeProblems(s, collisions);
    const copy_resolved = try resolveCopySuffixesOnDisk(s, built.ok);
    if (copy_resolved.problems.len > 0) return try describeProblems(s, copy_resolved.problems);

    const p = copy_resolved.plan;
    if (p.isEmpty()) {
        try s.state.dir.writeFile(s.io, .{ .sub_path = "preview", .data = "" });
        return null;
    }

    var base_dir = try openBase(s);
    defer base_dir.close(s.io);
    const missing = try missingDirs(s, base_dir, p.mkdirs);
    var preview_out: std.Io.Writer.Allocating = .init(s.arena);
    try writeDiff(s, &preview_out.writer, base_dir, p, missing);
    try s.state.dir.writeFile(s.io, .{ .sub_path = "preview", .data = preview_out.written() });
    return null;
}

fn describeProblems(s: *Session, problems: []const plan.Problem) ![]const u8 {
    var result: std.Io.Writer.Allocating = .init(s.arena);
    try result.writer.writeAll("buffer tem problemas: ");
    for (problems, 0..) |p, i| {
        if (i != 0) try result.writer.writeAll("; ");
        try p.describe(&result.writer);
    }
    return result.written();
}

fn formatFsError(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permissao negada",
        error.FileNotFound => "arquivo nao encontrado",
        error.ReadOnlyFileSystem => "sistema de arquivos somente leitura",
        error.DeviceOrResourceBusy => "recurso ocupado",
        error.DiskQuota => "cota de disco excedida",
        error.NoSpaceLeft => "sem espaco no dispositivo",
        error.SymlinkInPath => "symlink no caminho",
        error.PathAlreadyExists => "caminho ja existe",
        error.DirNotEmpty => "diretorio nao esta vazio",
        else => @errorName(err),
    };
}

fn applyApprovedLive(s: *Session, p: plan.Plan) !?[]const u8 {
    var base_dir = try openBase(s);
    defer base_dir.close(s.io);

    var effective = p;
    effective.mkdirs = try missingDirs(s, base_dir, p.mkdirs);

    var area_ptr: ?*fsops.Area = null;
    if (p.removes.len > 0) {
        area_ptr = ensureArea(s) catch |err| return try std.fmt.allocPrint(
            s.arena,
            "nao foi possivel abrir a area de sessao ({s})",
            .{formatFsError(err)},
        );
    }

    const sources = try moveSources(s, effective);
    defer closeSources(s, sources);

    const outcome = try fsops.apply(s.arena, s.io, base_dir, effective, area_ptr, sources);
    if (outcome.failure) |failure| {
        return try std.fmt.allocPrint(s.arena, "falha em {s} {s}: {s}; rollback {s}", .{
            failure.phase,
            failure.detail,
            formatFsError(failure.err),
            if (outcome.rollback_errors.len == 0) "completo" else "incompleto",
        });
    }

    if (!outcome.applied.isEmpty()) {
        s.view.undo = .{
            .base = s.view.dir,
            .area = if (area_ptr) |a| a.name else null,
            .applied = outcome.applied,
        };
    }
    s.notice = try appliedNotice(s, outcome.applied);
    return null;
}

/// Para subir (`up`): a entrada com o basename do diretorio atual e onde o
/// cursor deve pousar na tela seguinte. O Vim consome e apaga o arquivo.
fn writeCursorNameHint(s: *Session) void {
    s.state.dir.writeFile(s.io, .{
        .sub_path = "cursor_name",
        .data = std.fs.path.basename(s.view.dir),
    }) catch {};
}

// ---------------------------------------------------------------------------
// Conteudo do buffer
// ---------------------------------------------------------------------------

const Collector = struct {
    session: *Session,
    entries: std.ArrayList(plan.Original) = .empty,
    unlistable: std.ArrayList([]const u8) = .empty,
    /// Maior indice consumido pela enumeracao. Entra no calculo da reserva de
    /// IDs porque entrada nao-listavel tambem gasta indice.
    high: u32 = 0,

    fn emit(ctx: *anyopaque, index: u32, e: explorer.Entry) anyerror!void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        if (index >= c.high) c.high = index + 1;
        if (e.parent) return; // `..` nao e entrada editavel; para subir existe `:cd ..`
        // O Vim nao preserva bytes invalidos no round-trip: o ID estaria certo e
        // o destino, corrompido. A entrada aparece, mas fora da edicao.
        if (!e.utf8_ok) {
            try c.unlistable.append(c.session.arena, e.path);
            return;
        }
        var display: std.Io.Writer.Allocating = .init(c.session.arena);
        try explorer.writeTableDetails(&display.writer, e);
        try c.entries.append(c.session.arena, .{
            .id = c.session.view.id_base + index,
            .path = e.path,
            .kind = e.kind,
            .display = display.written(),
        });
    }

    fn sink(c: *Collector) explorer.Sink {
        return .{ .ctx = c, .func = emit };
    }
};

/// IDs que ainda aparecem no texto do buffer daquele View, como ele esta no
/// disco agora. O helper grava todos os buffers de diretorio antes de pedir o
/// preview ou a aplicacao, entao isto e o que o usuario tem na tela -- e a
/// unica fonte de verdade sobre o que foi apagado e o que ficou. `null` quando
/// nao deu para ler ou o texto nao passa no parser: dai nada e deduzido.
fn idsInBuffer(s: *Session, v: *View) !?std.AutoHashMapUnmanaged(u32, void) {
    const text = Io.Dir.cwd().readFileAlloc(
        s.io,
        v.buffer_path,
        s.arena,
        .limited(64 * 1024 * 1024),
    ) catch return null;
    const parsed = try plan.parseBuffer(s.arena, text, v.header_lines);
    if (parsed == .invalid) return null;
    var set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (parsed.ok.edits) |e| try set.put(s.arena, e.id, {});
    return set;
}

/// Uma entrada deste buffer cuja linha foi colada no buffer de outra pasta.
const Claim = struct { id: u32, path: []const u8, dir: []const u8 };

const CrossBuffers = struct {
    /// IDs dos outros buffers abertos, com a origem absoluta de cada um. E o
    /// que permite colar de uma janela na outra: o numero da linha yankada nao
    /// pertence a este buffer, mas a sessao sabe de onde ele veio. Sem isto o
    /// plano so pode recusa-lo como adulteracao.
    foreign: *const plan.ForeignMap,
    /// O caminho inverso: IDs daqui que apareceram la.
    claims: []const Claim,
};

/// O que os outros buffers da sessao dizem sobre os IDs. Le o texto de cada um
/// como esta no disco, entao distingue as duas metades do gesto do oil: a linha
/// que **ficou** na origem e colada aqui e copia; a que **sumiu** de la e
/// movimento. Quem decide e o estado dos buffers, nao um registro de recorte
/// paralelo -- que seria uma segunda verdade sobre a mesma coisa.
fn crossBuffers(s: *Session) !CrossBuffers {
    const foreign = try s.arena.create(plan.ForeignMap);
    foreign.* = .empty;
    var claims: std.ArrayList(Claim) = .empty;

    var mine: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    for (s.view.entries) |e| try mine.put(s.arena, e.id, e.path);

    var it = s.views.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        if (v == s.view) continue;
        const present = try idsInBuffer(s, v);
        for (v.entries) |e| {
            const abs = try std.fs.path.join(s.arena, &.{ v.dir, e.path });
            // Sem conseguir ler o buffer de origem fica copia: e o desfecho
            // conservador, o unico que nao tira nada do lugar.
            const cut = if (present) |p| !p.contains(e.id) else false;
            try foreign.put(s.arena, e.id, .{ .path = abs, .kind = e.kind, .cut = cut });
        }
        const p = present orelse continue;
        var pit = p.keyIterator();
        while (pit.next()) |id| {
            const path = mine.get(id.*) orelse continue;
            try claims.append(s.arena, .{ .id = id.*, .path = path, .dir = v.dir });
        }
    }
    return .{ .foreign = foreign, .claims = try claims.toOwnedSlice(s.arena) };
}

/// Monta o plano deste buffer depois de ouvir os outros. Uma linha apagada aqui
/// e colada la nao vira remocao: o movimento inteiro pertence ao buffer de
/// destino, que e onde ele esta visivel, e e o `:w` de la que o conclui.
/// Aplicar a remocao aqui mandaria o arquivo para a area de sessao e o outro
/// `:w` nao teria mais de onde mover.
fn buildPlan(s: *Session, document: plan.Document) !plan.Result {
    const cross = try crossBuffers(s);

    var kept: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (document.edits) |e| try kept.put(s.arena, e.id, {});
    var problems: std.ArrayList(plan.Problem) = .empty;
    for (cross.claims) |c| {
        if (kept.contains(c.id)) continue;
        try problems.append(s.arena, .{
            .claimed_elsewhere = .{ .id = c.id, .path = c.path, .dir = c.dir },
        });
    }
    if (problems.items.len > 0) return .{ .invalid = try problems.toOwnedSlice(s.arena) };

    return plan.build(s.arena, s.view.entries, document.edits, document.creates, .{
        .temp_prefix = try std.fmt.allocPrint(s.arena, ".lst-f-tmp-{d}-", .{s.pid}),
        .foreign = cross.foreign,
    });
}

fn loadListing(s: *Session) !void {
    var collector: Collector = .{ .session = s };
    var options = s.options;
    options.recursive = false;
    try explorer.enumerate(s.arena, s.io, s.view.dir, options, collector.sink());
    s.view.entries = try collector.entries.toOwnedSlice(s.arena);
    s.view.unlistable = try collector.unlistable.toOwnedSlice(s.arena);
    reserveIds(s, collector.high);
}

/// Garante que os IDs deste View nao colidem com os de nenhum outro buffer da
/// sessao. A reserva existente e reaproveitada enquanto couber, para que um
/// refresh nao troque os IDs debaixo de um buffer que o usuario esta editando.
/// `high` e o maior indice que a enumeracao consumiu, contando as entradas
/// nao-listaveis, que tambem gastam numero.
fn reserveIds(s: *Session, high: u32) void {
    const v = s.view;
    const need = high + 2;
    if (v.id_span >= need) return;
    const old_base = v.id_base;
    v.id_base = s.next_id;
    v.id_span = need;
    s.next_id = s.next_id + need;
    if (old_base == v.id_base) return;
    for (v.entries) |*e| e.id = e.id - old_base + v.id_base;
}

fn writeBuffer(s: *Session) !void {
    var base_dir = try openBase(s);
    defer base_dir.close(s.io);

    var notes: std.ArrayList([]const u8) = .empty;
    const orphans = fsops.scanOrphans(s.arena, s.io, base_dir, s.pid) catch &.{};
    for (orphans) |o| {
        try notes.append(s.arena, try std.fmt.allocPrint(
            s.arena,
            "area orfa {s} ({d} item(ns)) do PID {d}, que nao esta mais rodando",
            .{ o.name, o.items, o.pid },
        ));
    }
    try s.state.writeNotice(s.io, s.notice orelse "");

    var file = try Io.Dir.cwd().createFile(s.io, s.view.buffer_path, .{ .truncate = true });
    defer file.close(s.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .init(file, s.io, &buffer);
    const location = try std.fmt.allocPrint(s.arena, "{s}{s}", .{
        abbreviateHome(s.arena, s.environ, s.view.dir),
        if (s.options.show_hidden) "  [all]" else "",
    });
    // A sessao viva recarrega o buffer sem reabrir o editor: o lado do Vim
    // le daqui o diretorio corrente para sincronizar cwd e moldura. Global
    // para o self-exec de preview do fzf; os sidecars por buffer sao o que o
    // helper usa, porque com duas janelas nao ha "corrente" unico.
    try s.state.writeBase(s.io, s.view.dir);
    try s.state.dir.writeFile(s.io, .{ .sub_path = "location", .data = location });
    try s.environ.put(session.env_location, location);
    const header: plan.BufferHeader = .{
        .scope = null,
        .unlistable = s.view.unlistable,
        .notes = notes.items,
    };
    s.view.header_lines = try plan.headerLines(s.arena, header);
    try s.state.writeHeader(s.io, s.arena, s.view.header_lines);
    try s.state.writeTitles(s.io, explorer.table_titles);
    try plan.writeBuffer(s.arena, &writer.interface, header, s.view.entries);
    try writer.interface.flush();
    try writeViewSidecars(s, location);
    // O aviso ja esta no arquivo que sera aberto agora; a proxima navegacao
    // parte de uma tela limpa.
    s.notice = null;
    try writeTree(s);
}

/// Sidecars de um buffer de diretorio: o que o helper precisa para desenhar
/// aquela janela sem depender de estado global. Vivem ao lado do arquivo de
/// conteudo (`NNNN.lstf.dir`, `.location`, `.header`).
fn writeViewSidecars(s: *Session, location: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const dir_path = try std.fmt.allocPrint(s.arena, "{s}.dir", .{s.view.buffer_path});
    try cwd.writeFile(s.io, .{ .sub_path = dir_path, .data = s.view.dir });
    const loc_path = try std.fmt.allocPrint(s.arena, "{s}.location", .{s.view.buffer_path});
    try cwd.writeFile(s.io, .{ .sub_path = loc_path, .data = location });
    const hdr_joined = try std.mem.join(s.arena, "\n", s.view.header_lines);
    const hdr_path = try std.fmt.allocPrint(s.arena, "{s}.header", .{s.view.buffer_path});
    try cwd.writeFile(s.io, .{ .sub_path = hdr_path, .data = hdr_joined });
    // O aviso tambem e por buffer: com duas janelas, o arquivo global de aviso
    // e o de quem pediu por ultimo, e o recado de uma apareceria na barra da
    // outra.
    const note_path = try std.fmt.allocPrint(s.arena, "{s}.notice", .{s.view.buffer_path});
    try cwd.writeFile(s.io, .{ .sub_path = note_path, .data = s.notice orelse "" });
}

fn editorLabel(editor: editor_mod.Editor) []const u8 {
    const name = editor.name();
    return if (std.mem.indexOf(u8, name, "nvim") != null) "Neovim" else "Vim";
}

const TreeWriter = struct {
    writer: *Io.Writer,
    count: usize = 0,

    const limit: usize = 2_000;
    const LimitReached = error{TreeLimitReached};

    fn emit(ctx: *anyopaque, _: u32, e: explorer.Entry) anyerror!void {
        const t: *TreeWriter = @ptrCast(@alignCast(ctx));
        if (e.parent) return;
        if (t.count >= limit) return LimitReached.TreeLimitReached;
        t.count += 1;
        const depth = std.mem.count(u8, e.path, "/");
        try t.writer.splatBytesAll("│   ", depth);
        try t.writer.writeAll("├── ");
        try t.writer.writeAll(std.fs.path.basename(e.path));
        if (e.kind == .dir) try t.writer.writeByte('/');
        if (e.symlink) try t.writer.writeAll(" @");
        try t.writer.writeByte('\n');
    }

    fn sink(t: *TreeWriter) explorer.Sink {
        return .{ .ctx = t, .func = emit };
    }
};

/// Produz uma arvore visual pelo mesmo enumerador que aplica os limites de
/// profundidade, symlinks e pontos de montagem da CLI.
fn writeTree(s: *Session) !void {
    var tree = try s.state.treeFile(s.io);
    defer tree.close(s.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .init(tree, s.io, &buffer);
    const w = &writer.interface;
    try w.print("{s}\n", .{abbreviateHome(s.arena, s.environ, s.view.dir)});
    var options = s.options;
    options.recursive = true;
    var out: TreeWriter = .{ .writer = w };
    explorer.enumerate(s.arena, s.io, s.view.dir, options, out.sink()) catch |err| {
        if (err != TreeWriter.LimitReached.TreeLimitReached) return err;
        try w.print("… arvore truncada em {d} entradas\n", .{TreeWriter.limit});
    };
    try w.flush();
}

fn changeDir(s: *Session, target: []const u8) !void {
    _ = enterDirQuiet(s, target);
}

fn expandHome(s: *Session, target: []const u8) []const u8 {
    const home = s.environ.get("HOME") orelse return target;
    if (home.len == 0) return target;
    if (std.mem.eql(u8, target, "~") or target.len == 0) return home;
    if (std.mem.startsWith(u8, target, "~/")) {
        return std.fs.path.join(s.arena, &.{ home, target[2..] }) catch target;
    }
    return target;
}

/// Troca o foco para o View de `dir` e recarrega a listagem. Navegar nao
/// reescreve o View de origem: cada diretorio tem o seu, e e isso que permite
/// duas janelas com dois diretorios sem que uma pise na outra.
fn switchView(s: *Session, dir: []const u8) bool {
    const from = s.view;
    const v = s.views.getOrCreate(s.arena, s.io, s.state.path, dir) catch {
        s.notice = "nao consegui abrir o buffer deste diretorio";
        return false;
    };
    if (v == from) {
        loadListing(s) catch {
            s.notice = "nao consegui listar o diretorio";
            return false;
        };
        return true;
    }
    // View novo herda o trilho de quem o abriu: `<` e `>` continuam fazendo
    // sentido dentro daquela janela.
    if (v.history.items.items.len == 0) {
        v.history = from.history.clone(s.arena) catch .{};
        v.history.push(s.arena, dir) catch {};
    }
    s.view = v;
    loadListing(s) catch {
        s.notice = "nao consegui listar o diretorio";
        return false;
    };
    return true;
}

/// Entra em `target`, relativo ao diretorio do buffer em foco quando o caminho
/// nao e absoluto. Silencioso: falha vai para `s.notice` (chip da proxima
/// tela), nunca para o terminal -- durante a sessao viva a tela e do editor.
/// `true` quando entrou.
fn enterDirQuiet(s: *Session, raw_target: []const u8) bool {
    const target = expandHome(s, raw_target);
    const joined = if (std.fs.path.isAbsolute(target))
        target
    else
        std.fs.path.join(s.arena, &.{ s.view.dir, target }) catch return false;

    const resolved = Io.Dir.cwd().realPathFileAlloc(s.io, joined, s.arena) catch {
        s.notice = std.fmt.allocPrint(s.arena, "nao consegui entrar em {s}", .{raw_target}) catch null;
        return false;
    };
    const st = Io.Dir.cwd().statFile(s.io, resolved, .{}) catch {
        s.notice = std.fmt.allocPrint(s.arena, "nao consegui entrar em {s}", .{raw_target}) catch null;
        return false;
    };
    if (st.kind != .directory) {
        s.notice = std.fmt.allocPrint(s.arena, "{s} nao e um diretorio", .{raw_target}) catch null;
        return false;
    }
    return switchView(s, resolved);
}

/// `<` e `>` andam sobre o trilho de quem navegou, e o trilho viaja junto:
/// o View de destino adota a posicao corrente, senao o `forward` se perderia
/// ao voltar para um View cujo trilho proprio e mais curto.
fn goBack(s: *Session) !void {
    const target = s.view.history.back() orelse {
        s.notice = "nao ha para onde voltar nesta sessao";
        return;
    };
    const trail = s.view.history;
    if (!try enterVisited(s, target)) {
        s.view.history = trail;
        _ = s.view.history.forward();
        return;
    }
    s.view.history = trail;
}

fn goForward(s: *Session) !void {
    const target = s.view.history.forward() orelse {
        s.notice = "nao ha para onde avancar nesta sessao";
        return;
    };
    const trail = s.view.history;
    if (!try enterVisited(s, target)) {
        s.view.history = trail;
        _ = s.view.history.back();
        return;
    }
    s.view.history = trail;
}

/// Volta a um diretorio ja visitado. `false` quando ele sumiu no meio da
/// sessao: o passo e desfeito e a tela nao sai do lugar.
fn enterVisited(s: *Session, target: []const u8) !bool {
    const st = Io.Dir.cwd().statFile(s.io, target, .{}) catch {
        s.notice = try std.fmt.allocPrint(s.arena, "{s} nao esta mais acessivel", .{target});
        return false;
    };
    if (st.kind != .directory) {
        s.notice = try std.fmt.allocPrint(s.arena, "{s} nao e mais um diretorio", .{target});
        return false;
    }
    if (!switchView(s, target)) return false;
    return true;
}

fn openFileInEditor(s: *Session, target: []const u8) !void {
    // Ao abrir um arquivo para edicao, respeita $VISUAL ou $EDITOR se definido;
    // se nenhum estiver definido ou se falhar, usa o editor da sessao / vim como fallback.
    const preferred = s.environ.get("VISUAL") orelse s.environ.get("EDITOR") orelse s.editor_spec;
    const editor = editor_mod.resolve(s.arena, s.io, s.environ, preferred) catch {
        const fallback = editor_mod.resolve(s.arena, s.io, s.environ, s.editor_spec) catch |err| {
            try explainEditor(s.out, err);
            return;
        };
        _ = editor_mod.run(
            s.arena,
            s.io,
            fallback,
            s.environ,
            target,
            s.view.dir,
            null,
        ) catch |err| {
            try s.out.print("lst-f: falha ao abrir arquivo no editor: {s}\n", .{@errorName(err)});
        };
        try loadListing(s);
        return;
    };
    _ = editor_mod.run(
        s.arena,
        s.io,
        editor,
        s.environ,
        target,
        s.view.dir,
        null,
    ) catch |err| {
        try s.out.print("lst-f: falha ao abrir arquivo no editor: {s}\n", .{@errorName(err)});
    };
    try loadListing(s);
}

fn openShell(s: *Session, target: ?[]const u8) !void {
    const shell = s.environ.get("SHELL") orelse "/bin/sh";
    var dir_to_open = s.view.dir;
    if (target) |t| {
        const trimmed = std.mem.trim(u8, t, " \t");
        if (trimmed.len > 0) {
            if (trimmed[0] == '~') {
                if (s.environ.get("HOME")) |home| {
                    if (trimmed.len == 1) {
                        dir_to_open = home;
                    } else if (trimmed[1] == '/') {
                        dir_to_open = try std.fmt.allocPrint(s.arena, "{s}{s}", .{ home, trimmed[1..] });
                    }
                }
            } else if (trimmed[0] == '/') {
                dir_to_open = trimmed;
            } else {
                dir_to_open = try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ s.view.dir, trimmed });
            }
        }
    }

    var child = std.process.spawn(s.io, .{
        .argv = &.{shell},
        .environ_map = s.environ,
        .cwd = .{ .path = dir_to_open },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        try s.out.print("lst-f: falha ao abrir terminal ({s}): {s}\n", .{ dir_to_open, @errorName(err) });
        try pause(s);
        return;
    };
    _ = child.wait(s.io) catch {};
    try loadListing(s);
}

// ---------------------------------------------------------------------------
// Buscador
// ---------------------------------------------------------------------------

const Feed = struct {
    records: *Io.Writer,
    list: *Io.Writer,
    options: explorer.Options,
    paths: std.ArrayList(explorer.Entry) = .empty,
    arena: Allocator,
    /// Maior indice visto; mesma funcao do `Collector.high`.
    high: u32 = 0,

    fn emit(ctx: *anyopaque, index: u32, e: explorer.Entry) anyerror!void {
        const f: *Feed = @ptrCast(@alignCast(ctx));
        if (index >= f.high) f.high = index + 1;
        if (e.parent) return;
        try f.paths.append(f.arena, e);
        // Campo 1 e o indice, nunca o caminho: nome de arquivo pode conter TAB.
        try f.records.print("{d}\t", .{index});
        try fzf.writeDisplay(f.records, e, f.options);
        try f.records.writeByte(0);
        try f.list.print("{s}\x00", .{e.path});
    }

    fn sink(f: *Feed) explorer.Sink {
        return .{ .ctx = f, .func = emit };
    }
};

/// Abre o fzf sobre a arvore a partir do diretorio corrente. O que for marcado
/// vira o conteudo do buffer. Devolve `false` quando nada foi escolhido.
fn runFind(s: *Session, query: []const u8) !bool {
    if (s.features.version.major == 0 and s.features.version.minor == 0) {
        s.notice = "o fzf nao esta disponivel; a busca depende dele";
        return false;
    }

    try s.state.writeBase(s.io, s.view.dir);

    var options = s.options;
    options.recursive = true;

    var runner = try fzf.start(s.arena, s.io, .{
        .features = s.features,
        .header = try findHeader(s),
        .prompt = "find> ",
        .query = query,
        .environ = s.environ,
        .color = s.options.color,
        .preview = true,
    });

    var list_file = try s.state.listFile(s.io);
    var list_buffer: [64 * 1024]u8 = undefined;
    var list_writer: Io.File.Writer = .init(list_file, s.io, &list_buffer);

    var feed: Feed = .{
        .records = runner.writer(),
        .list = &list_writer.interface,
        .options = options,
        .arena = s.arena,
    };
    // Streaming: o fzf ja mostra as primeiras entradas enquanto a arvore ainda
    // esta sendo percorrida.
    explorer.enumerate(s.arena, s.io, s.view.dir, options, feed.sink()) catch {};
    list_writer.interface.flush() catch {};
    list_file.close(s.io);

    const selection = try runner.finish(s.arena);
    if (selection.aborted) return false;
    if (std.mem.eql(u8, selection.key, fzf.Keys.help)) {
        try s.out.writeByte('\n');
        try printHelp(s.out);
        try pause(s);
        return runFind(s, query);
    }
    if (selection.indices.len == 0) return false;

    var entries: std.ArrayList(plan.Original) = .empty;
    var unlistable: std.ArrayList([]const u8) = .empty;
    for (selection.indices) |index| {
        if (index >= feed.paths.items.len) continue;
        const e = feed.paths.items[index];
        if (!e.utf8_ok) {
            try unlistable.append(s.arena, e.path);
            continue;
        }
        var display: std.Io.Writer.Allocating = .init(s.arena);
        try explorer.writeTableDetails(&display.writer, e);
        try entries.append(s.arena, .{
            .id = s.view.id_base + index,
            .path = e.path,
            .kind = e.kind,
            .display = display.written(),
        });
    }
    if (entries.items.len == 0 and unlistable.items.len == 0) return false;

    s.view.entries = try entries.toOwnedSlice(s.arena);
    s.view.unlistable = try unlistable.toOwnedSlice(s.arena);
    reserveIds(s, feed.high);
    s.notice = if (query.len > 0)
        try std.fmt.allocPrint(s.arena, "resultado de :find {s} ({d} marcada(s))", .{ query, s.view.entries.len })
    else
        try std.fmt.allocPrint(s.arena, "resultado de :find ({d} marcada(s))", .{s.view.entries.len});
    return true;
}

fn findHeader(s: *Session) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(s.arena);
    const w = &buf.writer;
    const width: usize = @max(40, terminalWidth() -| gutter);

    const location = try std.fmt.allocPrint(s.arena, "{s}  [arvore]{s}", .{
        abbreviateHome(s.arena, s.environ, s.view.dir),
        if (s.options.show_hidden) " [all]" else "",
    });
    const badge = try std.fmt.allocPrint(s.arena, "{s} ajuda  \u{00b7}  {s} v{s}", .{
        fzf.Keys.help_label,
        build_options.app_name,
        build_options.version,
    });
    try writeEllipsized(w, location, width -| (badge.len + 2));
    const used = @min(location.len, width -| (badge.len + 2));
    try w.splatByteAll(' ', width -| (used + badge.len));
    try w.writeAll(badge);
    try w.writeByte('\n');

    try fzf.writeColumnTitles(w, s.options);
    try w.writeByte('\n');
    try w.splatBytesAll("\u{2500}", width);
    return buf.written();
}

/// Colunas que o fzf consome a esquerda do texto (ponteiro e marcador).
const gutter = 4;

fn terminalWidth() usize {
    if (@import("builtin").os.tag != .linux) return 80;
    var ws: std.posix.winsize = undefined;
    for ([_]std.posix.fd_t{ std.posix.STDERR_FILENO, std.posix.STDOUT_FILENO }) |fd| {
        const rc = linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (linux.errno(rc) == .SUCCESS and ws.col > 0) return ws.col;
    }
    return 80;
}

fn writeEllipsized(w: *Io.Writer, text: []const u8, width: usize) !void {
    if (text.len <= width) {
        try w.writeAll(text);
        return;
    }
    if (width <= 1) return;
    // Corta pela esquerda: o fim do caminho e o que interessa.
    try w.writeAll("<");
    try w.writeAll(text[text.len - (width - 1) ..]);
}

fn abbreviateHome(_: Allocator, _: *const std.process.Environ.Map, path: []const u8) []const u8 {
    return path;
}

// ---------------------------------------------------------------------------
// Aplicacao
// ---------------------------------------------------------------------------

fn openBase(s: *Session) !Io.Dir {
    return Io.Dir.cwd().openDir(s.io, s.view.dir, .{ .iterate = true });
}

/// Criacao que colide com o que ja esta no disco sem estar na listagem
/// (dotfile com `show_hidden` desligado, entrada de outro filtro). Pegar aqui
/// evita que a falha aconteca no meio da aplicacao e arraste tudo no rollback.
fn checkCreatesOnDisk(s: *Session, p: plan.Plan) ![]const plan.Problem {
    if (p.creates.len == 0) return &.{};

    var base_dir = try openBase(s);
    defer base_dir.close(s.io);

    var out: std.ArrayList(plan.Problem) = .empty;
    for (p.creates) |c| {
        const st = base_dir.statFile(s.io, c.path, .{ .follow_symlinks = false }) catch continue;
        // Pai que ja existe como diretorio e exatamente o que se espera.
        if (c.implicit and st.kind == .directory) continue;
        // Nome que uma renomeacao libera antes: as criacoes vem depois dela.
        if (vacatedByMove(p, c.path)) continue;
        try out.append(s.arena, .{ .create_exists = .{ .line = c.line, .path = c.path } });
    }
    return out.toOwnedSlice(s.arena);
}

fn vacatedByMove(p: plan.Plan, path: []const u8) bool {
    for (p.moves) |m| {
        if (std.mem.eql(u8, m.from, path)) return true;
    }
    return false;
}

const CopyResolve = struct { plan: plan.Plan, problems: []const plan.Problem };

/// Resolve o destino das copias contra o plano e o disco: colisao recebe
/// sufixo `-NN` (01..99), em qualquer diretorio. O disco cobre o que a
/// listagem nao enxerga (subdiretorio do painel de destino, dotfile oculto).
fn resolveCopySuffixesOnDisk(s: *Session, p: plan.Plan) !CopyResolve {
    if (p.copies.len == 0) return .{ .plan = p, .problems = &.{} };

    var base_dir = try openBase(s);
    defer base_dir.close(s.io);

    // Caminhos que o plano reserva ou libera.
    var occupied: std.StringHashMapUnmanaged(void) = .empty;
    var freed: std.StringHashMapUnmanaged(void) = .empty;
    for (p.moves) |m| {
        try occupied.put(s.arena, m.to, {});
        try freed.put(s.arena, m.from, {});
    }
    // So as remocoes antecipadas liberam nome a tempo: elas rodam na fase 2,
    // antes das copias. As demais sao a ultima fase, depois da copia, entao o
    // nome delas ainda esta ocupado na hora de copiar. O `plan` ja antecipa a
    // remocao que libera um destino de copia; contar as outras aqui daria o
    // nome por livre e a aplicacao estouraria em `PathAlreadyExists`.
    for (p.removes[0..p.removes_before]) |rm| try freed.put(s.arena, rm.path, {});
    for (p.creates) |c| try occupied.put(s.arena, c.path, {});

    // `rename` nao atravessa ponto de montagem, entao um movimento cuja origem
    // esta em outro filesystem vira copia + remocao. Quem sabe disso e esta
    // camada, que conhece o disco; o plano so carrega o veredito.
    const base_device = fsops.deviceOf(s.io, s.view.dir);

    var problems: std.ArrayList(plan.Problem) = .empty;
    var copies = try s.arena.alloc(plan.Copy, p.copies.len);
    for (p.copies, 0..) |c, i| {
        copies[i] = c;
        if (c.cut) {
            if (c.from_abs) |abs| {
                const dir = std.fs.path.dirname(abs) orelse "/";
                const src_device = fsops.deviceOf(s.io, dir);
                // Sem conseguir medir, assume o caminho que sempre funciona.
                copies[i].cross_device = base_device == null or src_device == null or
                    src_device.? != base_device.?;
            }
        }
        // Origem em outra pasta: o `plan` e puro e nao conhece caminhos
        // absolutos, entao a checagem de "copiar para dentro de si mesmo"
        // acontece aqui, onde os dois lados sao conhecidos. Sem ela a
        // aplicacao recursiona ate estourar PATH_MAX.
        if (c.from_abs) |abs_from| {
            const abs_to = try std.fs.path.join(s.arena, &.{ s.view.dir, c.to });
            if (plan.isUnder(abs_from, abs_to)) {
                try problems.append(s.arena, .{ .copy_into_self = .{ .id = c.id, .from = abs_from, .to = abs_to } });
                continue;
            }
        }
        var to = c.to;
        if (busyCopyDest(s, base_dir, to, &occupied, &freed)) {
            if (c.cut) {
                // Movimento nao inventa nome. O sufixo `-01` e o gesto de
                // duplicar, que so faz sentido quando a origem fica onde esta;
                // aqui ela sai do lugar, e escolher por conta propria entre os
                // dois arquivos perderia um deles em silencio.
                try problems.append(s.arena, .{ .move_dest_occupied = .{
                    .id = c.id,
                    .from = c.from_abs orelse c.from,
                    .to = to,
                } });
                continue;
            }
            var n: u32 = 1;
            var resolved: ?[]const u8 = null;
            while (n < 100) : (n += 1) {
                const candidate = try plan.suffixed(s.arena, to, n, c.kind == .dir);
                if (!busyCopyDest(s, base_dir, candidate, &occupied, &freed)) {
                    try occupied.put(s.arena, candidate, {});
                    resolved = candidate;
                    break;
                }
            }
            if (resolved) |r| {
                to = r;
            } else {
                try problems.append(s.arena, .{ .copy_no_free_name = .{ .id = c.id, .path = to } });
                continue;
            }
        } else {
            try occupied.put(s.arena, to, {});
        }
        copies[i].to = to;
    }

    var result = p;
    result.copies = copies;
    return .{ .plan = result, .problems = try problems.toOwnedSlice(s.arena) };
}

fn busyCopyDest(
    s: *Session,
    base_dir: Io.Dir,
    path: []const u8,
    occupied: *const std.StringHashMapUnmanaged(void),
    freed: *const std.StringHashMapUnmanaged(void),
) bool {
    if (occupied.contains(path)) return true;
    if (freed.contains(path)) return false;
    _ = base_dir.statFile(s.io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// `false` quando o usuario recusou tudo ou a aplicacao falhou.
fn confirmAndApply(s: *Session, p: plan.Plan, approved_in_editor: bool) !bool {
    var base_dir = try openBase(s);
    defer base_dir.close(s.io);

    const missing = try missingDirs(s, base_dir, p.mkdirs);
    try renderDiff(s, base_dir, p, missing);

    var effective = p;
    effective.mkdirs = missing;

    if (!approved_in_editor and (p.moves.len > 0 or p.creates.len > 0 or p.copies.len > 0 or missing.len > 0)) {
        const question = if (p.moves.len == 0 and p.copies.len == 0)
            "Apply creations?"
        else if (p.creates.len == 0 and p.copies.len == 0)
            "Apply renames and moves?"
        else if (p.moves.len == 0 and p.creates.len == 0)
            "Apply copies?"
        else if (p.creates.len == 0)
            "Apply renames, moves, and copies?"
        else
            "Apply creations, renames, moves, and copies?";
        if (!try confirm(s, question)) {
            effective.moves = &.{};
            effective.renames = &.{};
            effective.mkdirs = &.{};
            effective.creates = &.{};
            effective.copies = &.{};
        }
    }

    var area_ptr: ?*fsops.Area = null;
    if (p.removes.len > 0) {
        if (approved_in_editor or try confirm(s, "Confirm removals?")) {
            area_ptr = ensureArea(s) catch |err| blk: {
                if (err == error.AreaUnavailable) {
                    try s.out.writeAll(
                        "lst-f: sem permissao de escrita no diretorio-base: nao da para criar a\n" ++
                            "       area de sessao, logo nao ha como garantir o rollback. As remocoes\n" ++
                            "       foram recusadas; as renomeacoes seguem.\n",
                    );
                } else {
                    try s.out.print("lst-f: nao foi possivel abrir a area de sessao: {s}\n", .{@errorName(err)});
                }
                break :blk null;
            };
        }
        if (area_ptr == null) {
            effective.removes = &.{};
            effective.removes_before = 0;
        }
    }

    if (effective.isEmpty()) {
        s.notice = "nada foi aplicado";
        return false;
    }

    const sources = try moveSources(s, effective);
    defer closeSources(s, sources);

    const outcome = try fsops.apply(s.arena, s.io, base_dir, effective, area_ptr, sources);
    if (outcome.failure) |failure| {
        // Em falha, o relatorio precisa permanecer visivel antes de voltar ao
        // editor para que o estado e a recuperacao manual fiquem claros.
        _ = failure;
        try reportOutcome(s, outcome);
        try pause(s);
        return false;
    }

    if (!outcome.applied.isEmpty()) {
        s.view.undo = .{
            .base = s.view.dir,
            .area = if (area_ptr) |a| a.name else null,
            .applied = outcome.applied,
        };
    }
    s.notice = try appliedNotice(s, outcome.applied);
    return true;
}

/// Resumo curto para a barra de baixo: so o que aconteceu, sem os zeros. O
/// relatorio completo continua indo para o terminal, onde ha espaco.
fn appliedNotice(s: *Session, applied: fsops.Applied) ![]const u8 {
    var parents: usize = applied.created_dirs.len;
    var created_files: usize = 0;
    var created_links: usize = 0;
    for (applied.created) |c| {
        if (c.implicit) {
            parents += 1;
        } else if (c.kind == .symlink or c.kind == .hardlink) {
            created_links += 1;
        } else {
            created_files += 1;
        }
    }

    var parts: std.ArrayList([]const u8) = .empty;
    if (created_files > 0) {
        try parts.append(s.arena, try std.fmt.allocPrint(s.arena, "{d} criado(s)", .{created_files}));
    }
    if (created_links > 0) {
        try parts.append(s.arena, try std.fmt.allocPrint(s.arena, "{d} link(s)", .{created_links}));
    }
    // Copia e movimento vindo de outra pasta andam na mesma lista, mas o que o
    // usuario precisa ler e se a origem ficou onde estava.
    var moved_in: usize = 0;
    var copied: usize = 0;
    for (applied.copied) |c| {
        if (c.cut) moved_in += 1 else copied += 1;
    }
    if (copied > 0) {
        try parts.append(s.arena, try std.fmt.allocPrint(s.arena, "{d} copiado(s)", .{copied}));
    }
    if (moved_in > 0) {
        try parts.append(s.arena, try std.fmt.allocPrint(s.arena, "{d} movido(s) para ca", .{moved_in}));
    }
    if (applied.renames.len > 0) {
        try parts.append(s.arena, try std.fmt.allocPrint(s.arena, "{d} renomeado(s)", .{applied.renames.len}));
    }
    if (parents > 0) {
        try parts.append(s.arena, try std.fmt.allocPrint(s.arena, "{d} pai(s)", .{parents}));
    }
    if (applied.removed.len > 0) {
        try parts.append(s.arena, try std.fmt.allocPrint(s.arena, "{d} removido(s)", .{applied.removed.len}));
    }
    if (parts.items.len == 0) return "nada foi aplicado";

    const summary = try std.mem.join(s.arena, ", ", parts.items);
    if (applied.removed.len > 0) {
        return std.fmt.allocPrint(s.arena, "aplicado: {s}  ·  :undo desfaz", .{summary});
    }
    return std.fmt.allocPrint(s.arena, "aplicado: {s}", .{summary});
}

fn missingDirs(s: *Session, base_dir: Io.Dir, dirs: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (dirs) |d| {
        _ = base_dir.statFile(s.io, d, .{ .follow_symlinks = false }) catch {
            try out.append(s.arena, d);
            continue;
        };
    }
    return out.toOwnedSlice(s.arena);
}

fn renderDiff(s: *Session, base_dir: Io.Dir, p: plan.Plan, missing: []const []const u8) !void {
    try writeDiff(s, s.out, base_dir, p, missing);
}

/// Uma das duas metades de `copies`: as que tiram a origem do lugar (`cut`) ou
/// as que a deixam. Nada e impresso quando a metade esta vazia.
fn writeCopySection(s: *Session, w: *Io.Writer, copies: []const plan.Copy, cut: bool, title: []const u8) !void {
    var count: usize = 0;
    var width: usize = 0;
    for (copies) |c| {
        if (c.cut != cut) continue;
        count += 1;
        width = @max(width, copyFrom(s, c).len);
    }
    if (count == 0) return;
    width = @min(width, 48);
    try w.print("{s} ({d}):\n", .{ title, count });
    for (copies) |c| {
        if (c.cut != cut) continue;
        const from = copyFrom(s, c);
        try w.print("  {s}", .{from});
        try w.splatByteAll(' ', width -| from.len);
        try w.print("  ->  {s}{s}\n", .{ c.to, if (c.kind == .dir) "/" else "" });
    }
    try w.writeAll("\n");
}

/// Origem como o usuario a le: relativa quando e daqui, absoluta com o home
/// abreviado quando vem de outra pasta -- que e a informacao que importa numa
/// operacao entre janelas.
fn copyFrom(s: *Session, c: plan.Copy) []const u8 {
    const abs = c.from_abs orelse return c.from;
    return abbreviateHome(s.arena, s.environ, abs);
}

fn writeDiff(s: *Session, w: *Io.Writer, base_dir: Io.Dir, p: plan.Plan, missing: []const []const u8) !void {
    try w.writeAll("\n");

    var asked: usize = 0;
    for (p.creates) |c| {
        if (!c.implicit) asked += 1;
    }
    if (asked > 0) {
        try w.print("Create ({d}):\n", .{asked});
        for (p.creates) |c| {
            if (c.implicit) continue;
            if (c.kind == .symlink) {
                try w.print("  {s} -> {s}  (symlink)\n", .{ c.path, c.target orelse "" });
            } else if (c.kind == .hardlink) {
                try w.print("  {s} => {s}  (hardlink)\n", .{ c.path, c.target orelse "" });
            } else {
                try w.print("  {s}{s}\n", .{
                    c.path,
                    if (c.kind == .dir) "/" else "",
                });
            }
        }
        try w.writeAll("\n");
    }

    // Movimento vindo de outra pasta e copia sao secoes separadas: o que muda
    // entre eles e se a origem continua existindo, e essa e justamente a
    // pergunta que o usuario faz ao olhar o preview.
    try writeCopySection(s, w, p.copies, true, "Move from another folder");
    try writeCopySection(s, w, p.copies, false, "Copy");

    if (missing.len > 0) {
        try w.print("Create parent directory ({d}):\n", .{missing.len});
        for (missing) |d| try w.print("  {s}/\n", .{d});
        try w.writeAll("\n");
    }

    if (p.moves.len > 0) {
        try w.print("Rename or move ({d}):\n", .{p.moves.len});
        var width: usize = 0;
        for (p.moves) |m| width = @max(width, m.from.len);
        width = @min(width, 48);
        for (p.moves) |m| {
            try w.print("  {s}", .{m.from});
            try w.splatByteAll(' ', width -| m.from.len);
            try w.print("  ->  {s}\n", .{m.to});
        }
        try w.writeAll("\n");
    }

    if (p.removes.len > 0) {
        try w.print(
            "Remove ({d})  ->  session area .lst-f-{d}/, deleted on exit: after that\n" ++
                "              removal is permanent; this is not a trash bin.\n",
            .{ p.removes.len, s.pid },
        );
        for (p.removes) |rm| {
            if (rm.kind == .dir) {
                const count = fsops.subtreeCount(s.io, base_dir, rm.path);
                try w.print("  {s}/  ({d} item(s) in subtree)\n", .{ rm.path, count });
            } else {
                try w.print("  {s}\n", .{rm.path});
            }
        }
        try w.writeAll("\n");
    }

    if (p.unchanged > 0) try w.print("{d} entrada(s) sem mudanca.\n\n", .{p.unchanged});
}

fn reportOutcome(s: *Session, outcome: fsops.Outcome) !void {
    const w = s.out;
    if (outcome.failure) |f| {
        try w.print("\nFALHA em \"{s}\": {s} ({s})\n", .{ f.phase, f.detail, formatFsError(f.err) });
        if (outcome.rollback_errors.len == 0) {
            try w.writeAll("Rollback completo: nada foi alterado.\n");
        } else {
            try w.writeAll("O rollback nao conseguiu desfazer tudo. Estado a recuperar a mao:\n");
            for (outcome.rollback_errors) |e| try w.print("  {s}\n", .{e});
            try w.writeAll("Entradas que continuam aplicadas:\n");
            for (outcome.applied.created) |c| {
                try w.print("  {s}{s} criado\n", .{ c.path, if (c.kind == .dir) "/" else "" });
            }
            for (outcome.applied.renames) |r| try w.print("  {s} -> {s}\n", .{ r.from, r.to });
            for (outcome.applied.copied) |c| try w.print("  {s} -> {s} copiado\n", .{ c.from, c.to });
            for (outcome.applied.removed) |rm| {
                try w.print("  {s} esta em {s}/{s}\n", .{ rm.path, outcome.applied.area orelse "?", rm.stored });
            }
        }
        return;
    }

    try w.print(
        "\nAplicado: {d} criacao(oes), {d} copia(s), {d} renomeacao(oes), {d} diretorio(s)-pai, {d} remocao(oes).\n",
        .{
            outcome.applied.created.len,
            outcome.applied.copied.len,
            outcome.applied.renames.len,
            outcome.applied.created_dirs.len,
            outcome.applied.removed.len,
        },
    );
    if (outcome.applied.removed.len > 0) {
        try w.writeAll("Escreva :undo no buffer para desfazer enquanto a sessao estiver aberta.\n");
    }
}

fn reportProblems(s: *Session, problems: []const plan.Problem) !void {
    try s.out.writeAll("\nNada foi aplicado. O buffer tem problemas:\n");
    for (problems) |p| {
        try s.out.writeAll("  ");
        try p.describe(s.out);
        try s.out.writeByte('\n');
    }
    try s.out.writeAll("\nO buffer volta como voce deixou, para corrigir.\n");
    try pause(s);
}

// ---------------------------------------------------------------------------
// Area de sessao e undo
// ---------------------------------------------------------------------------

/// Area de sessao do diretorio em foco. Cada View tem a sua, aberta uma vez:
/// nao ha mais reabertura a cada navegacao, porque navegar troca de View.
fn ensureArea(s: *Session) !*fsops.Area {
    return ensureAreaFor(s, s.view);
}

/// A mesma area, para um View qualquer: um movimento entre filesystems remove
/// a origem, e a origem mora na pasta de outro buffer.
fn ensureAreaFor(s: *Session, v: *View) !*fsops.Area {
    if (v.area != null) return &v.area.?;

    var dir = try Io.Dir.cwd().openDir(s.io, v.dir, .{ .iterate = true });
    defer dir.close(s.io);

    const name = try fsops.areaName(s.arena, s.pid);
    v.area = try fsops.openArea(s.arena, s.io, dir, name);
    v.area_name = name;
    try s.areas.append(s.arena, .{ .base = v.dir, .name = name });
    return &v.area.?;
}

/// Pastas de origem dos movimentos entre filesystems, com a area de sessao de
/// cada uma aberta. As areas entram no registro da sessao como as demais, para
/// que a saida limpa as apague -- senao o lst-f deixaria um `.lst-f-<pid>/` na
/// pasta alheia. Quem chama fecha os descritores.
fn moveSources(s: *Session, p: plan.Plan) ![]fsops.Source {
    var out: std.ArrayList(fsops.Source) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (p.copies) |c| {
        if (!c.cut or !c.cross_device) continue;
        const abs = c.from_abs orelse continue;
        const dir = std.fs.path.dirname(abs) orelse continue;
        if ((try seen.getOrPut(s.arena, dir)).found_existing) continue;
        const v = s.views.get(dir) orelse continue;
        const area = try ensureAreaFor(s, v);
        const handle = try Io.Dir.cwd().openDir(s.io, dir, .{ .iterate = true });
        try out.append(s.arena, .{ .dir = dir, .handle = handle, .area = area });
    }
    return out.toOwnedSlice(s.arena);
}

fn closeSources(s: *Session, sources: []fsops.Source) void {
    for (sources) |*src| src.handle.close(s.io);
}

fn undoLast(s: *Session) !void {
    const u = s.view.undo orelse {
        s.notice = "nada para desfazer nesta sessao";
        return;
    };

    var base_dir = Io.Dir.cwd().openDir(s.io, u.base, .{ .iterate = true }) catch {
        s.notice = "o diretorio da ultima operacao nao esta mais acessivel";
        return;
    };
    defer base_dir.close(s.io);

    var area_dir: ?Io.Dir = null;
    if (u.area) |name| {
        area_dir = base_dir.openDir(s.io, name, .{ .iterate = true }) catch null;
    }
    defer if (area_dir) |d| d.close(s.io);

    const errors = try fsops.revert(s.arena, s.io, base_dir, u.applied, area_dir);
    if (errors.len == 0) {
        // O movimento vindo de outra pasta voltou para la: aquele buffer
        // tambem mudou, e nao e o que esta em foco.
        _ = try refreshMovedSources(s, u.applied.copied, "devolvido pelo :undo");
        s.view.undo = null;
        s.notice = "ultima operacao desfeita";
    } else {
        try s.out.writeAll("\nO undo nao conseguiu desfazer tudo:\n");
        for (errors) |e| try s.out.print("  {s}\n", .{e});
    }
    if (errors.len > 0) try pause(s);
    try loadListing(s);
}

/// Saida limpa apaga as areas. A partir daqui a remocao e definitiva.
fn cleanupAreas(s: *Session) void {
    var it = s.views.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        if (v.area) |*a| {
            a.close(s.io);
            v.area = null;
        }
    }
    for (s.areas.items) |a| {
        var base_dir = Io.Dir.cwd().openDir(s.io, a.base, .{ .iterate = true }) catch continue;
        defer base_dir.close(s.io);
        base_dir.deleteTree(s.io, a.name) catch {};
    }
}

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------

const Tty = struct {
    file: Io.File,

    fn open(arena: Allocator, io: Io) ?Tty {
        const file = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_only }) catch return null;
        _ = arena;
        return .{ .file = file };
    }

    /// Cada volta do Vim restaura o terminal; recriar o leitor evita carregar
    /// estado/buffer da confirmacao anterior para a proxima operacao.
    fn line(t: Tty, arena: Allocator, io: Io) ?[]const u8 {
        const buffer = arena.alloc(u8, 1024) catch return null;
        var reader: Io.File.Reader = .initStreaming(t.file, io, buffer);
        return reader.interface.takeDelimiterExclusive('\n') catch null;
    }
};

fn confirm(s: *Session, question: []const u8) !bool {
    const tty = s.tty orelse return false;
    try s.out.print("{s} [y/N] ", .{question});
    try s.out.flush();
    const answer = tty.line(s.arena, s.io) orelse return false;
    const trimmed = std.mem.trim(u8, answer, " \t\r");
    return trimmed.len > 0 and (trimmed[0] == 's' or trimmed[0] == 'S' or
        trimmed[0] == 'y' or trimmed[0] == 'Y');
}

fn pause(s: *Session) !void {
    const tty = s.tty orelse return;
    try s.out.writeAll("\n[Press Enter to return to the list] ");
    try s.out.flush();
    _ = tty.line(s.arena, s.io);
}

fn report(s: *Session, message: []const u8) !void {
    try s.out.print("\nlst-f: {s}\n", .{message});
    try pause(s);
}

fn explainEditor(w: *Io.Writer, err: editor_mod.ResolveError) !void {
    switch (err) {
        error.NoEditor => try w.writeAll(
            "lst-f: vim nao foi encontrado no PATH, e o editor e a tela\n" ++
                "       do lst-f. Instale o vim ou use --editor <cmd> (ex.: nvim).\n",
        ),
        error.NotForeground => try w.writeAll(
            "lst-f: o editor configurado nao segura o terminal e devolveria o controle\n" ++
                "       antes da edicao. Use um editor de terminal, ou a flag de espera do seu\n" ++
                "       (code --wait, subl -w).\n",
        ),
    }
}

fn warnFzf(w: *Io.Writer, err: anyerror) !void {
    switch (err) {
        error.FzfNotFound => try w.writeAll(
            "lst-f: o fzf nao esta no PATH; :find nao vai funcionar. O resto da sessao\n" ++
                "       (listar, renomear, mover, remover) nao depende dele.\n",
        ),
        error.FzfTooOld => try w.print(
            "lst-f: fzf antigo demais para o preview; o piso e {d}.{d}. :find fica indisponivel.\n",
            .{ fzf.min_version.major, fzf.min_version.minor },
        ),
        else => try w.print("lst-f: fzf indisponivel ({s}); :find fica fora do ar.\n", .{@errorName(err)}),
    }
}
