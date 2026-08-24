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

pub const Command = union(enum) {
    browse: Browse,
    preview_index: u32,
    help,
    version,
};

pub const Browse = struct {
    dir: []const u8 = ".",
    editor: ?[]const u8 = null,
    /// Abre direto no buscador, com o termo ja digitado.
    find: ?[]const u8 = null,
    options: explorer.Options = .{},
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
        \\  -h, --help         esta ajuda
        \\  -V, --version      versao
        \\
        \\diretivas, escritas no proprio buffer:
        \\  :cd <dir>          entra no diretorio (.. sobe)
        \\  :hidden            alterna exibicao de arquivos ocultos
        \\  :find [termo]      busca fuzzy na arvore com o fzf; o que voce marcar
        \\                     vira o conteudo do buffer
        \\  :undo              desfaz a ultima operacao aplicada nesta sessao
        \\  :quit              sai (salvar sem mudancas tambem sai; :cq aborta)
        \\  .                  alterna exibicao de arquivos ocultos
        \\  Enter              abre o arquivo da linha ou entra no diretorio
        \\
        \\no buscador:
        \\  Tab                marca / desmarca      Enter  aceita a marcacao
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
    buffer_path: []const u8,
    helper_path: []const u8,
    /// Identidade exibida na barra permanente do buffer.
    editor_name: []const u8,

    base: []const u8,
    /// Conteudo corrente do buffer.
    entries: []const plan.Original = &.{},
    /// De onde o conteudo veio, quando nao e a listagem do diretorio.
    scope: ?[]const u8 = null,
    unlistable: []const []const u8 = &.{},
    /// Aviso de uma operacao concluida, mostrado uma vez no buffer reaberto.
    notice: ?[]const u8 = null,
    /// O buffer no disco ja serve; nao regerar (o usuario tem correcoes a fazer).
    keep_buffer: bool = false,
    /// Cabecalho do buffer que esta aberto agora. O parser precisa do texto
    /// exato para nao confundir cabecalho com nome de arquivo.
    header_lines: []const []const u8 = &.{},
    /// Diretorios visitados, para `:back` e `:forward`.
    history: session.History = .{},

    area: ?fsops.Area = null,
    area_base: []const u8 = "",
    areas: std.ArrayList(AreaRef) = .empty,
    undo: ?Undo = null,
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

    var s: Session = .{
        .arena = arena,
        .io = io,
        .out = out,
        .environ = environ,
        .tty = Tty.open(arena, io),
        .options = opts.options,
        .editor_spec = opts.editor,
        .editor_name = editorLabel(initial_editor),
        .features = features,
        .state = state,
        .pid = pid,
        .buffer_path = try std.fmt.allocPrint(arena, "{s}/lst-f.lstf", .{state.path}),
        .helper_path = helper_path,
        .base = base,
    };
    defer cleanupAreas(&s);
    try s.history.push(arena, s.base);

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
        if (!s.keep_buffer) {
            s.state.clearApproval(s.io);
            try writeBuffer(s);
        }
        s.keep_buffer = false;

        const editor = editor_mod.resolve(s.arena, s.io, s.environ, s.editor_spec) catch |err| {
            try explainEditor(s.out, err);
            return;
        };
        const result = editor_mod.run(
            s.arena,
            s.io,
            editor,
            s.environ,
            s.buffer_path,
            s.base,
            s.helper_path,
        ) catch |err| {
            try s.out.print("lst-f: falha ao abrir o editor: {s}\n", .{@errorName(err)});
            return;
        };
        // Sair com erro (:cq) e o sinal de "nao aplica nada", como no git commit.
        if (result == .aborted) {
            try s.out.writeAll("lst-f: editor saiu com erro; nada foi aplicado.\n");
            return;
        }

        const text = try Io.Dir.cwd().readFileAlloc(
            s.io,
            s.buffer_path,
            s.arena,
            .limited(64 * 1024 * 1024),
        );
        const parsed = try plan.parseBuffer(s.arena, text, s.header_lines);
        switch (parsed) {
            .invalid => |problems| {
                try reportProblems(s, problems);
                s.keep_buffer = true;
                continue;
            },
            .ok => {},
        }
        const document = parsed.ok;

        const built = try plan.build(s.arena, s.entries, document.edits, document.creates, .{
            .temp_prefix = try std.fmt.allocPrint(s.arena, ".lst-f-tmp-{d}-", .{s.pid}),
        });
        switch (built) {
            .invalid => |problems| {
                try reportProblems(s, problems);
                s.keep_buffer = true;
                continue;
            },
            .ok => {},
        }

        const collisions = try checkCreatesOnDisk(s, built.ok);
        if (collisions.len > 0) {
            try reportProblems(s, collisions);
            s.keep_buffer = true;
            continue;
        }

        const changed = !built.ok.isEmpty();
        if (changed) {
            const approved_in_editor = s.state.takeApproval(s.io);
            if (!try confirmAndApply(s, built.ok, approved_in_editor)) {
                // Depois de recusar a confirmacao, o buffer ainda contem as
                // linhas apagadas. Reabri-lo assim faria a mesma remocao ser
                // proposta indefinidamente, inclusive ao tentar sair.
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
        }
    }
}

// ---------------------------------------------------------------------------
// Conteudo do buffer
// ---------------------------------------------------------------------------

const Collector = struct {
    session: *Session,
    entries: std.ArrayList(plan.Original) = .empty,
    unlistable: std.ArrayList([]const u8) = .empty,

    fn emit(ctx: *anyopaque, index: u32, e: explorer.Entry) anyerror!void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
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
            .id = index,
            .path = e.path,
            .kind = e.kind,
            .display = display.written(),
        });
    }

    fn sink(c: *Collector) explorer.Sink {
        return .{ .ctx = c, .func = emit };
    }
};

fn loadListing(s: *Session) !void {
    var collector: Collector = .{ .session = s };
    var options = s.options;
    options.recursive = false;
    try explorer.enumerate(s.arena, s.io, s.base, options, collector.sink());
    s.entries = try collector.entries.toOwnedSlice(s.arena);
    s.unlistable = try collector.unlistable.toOwnedSlice(s.arena);
    s.scope = null;
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

    var file = try Io.Dir.cwd().createFile(s.io, s.buffer_path, .{ .truncate = true });
    defer file.close(s.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .init(file, s.io, &buffer);
    const location = try std.fmt.allocPrint(s.arena, "{s}{s}", .{
        abbreviateHome(s.arena, s.environ, s.base),
        if (s.options.show_hidden) "  [all]" else "",
    });
    try s.environ.put(session.env_location, location);
    const header: plan.BufferHeader = .{
        .scope = s.scope,
        .unlistable = s.unlistable,
        .notes = notes.items,
    };
    s.header_lines = try plan.headerLines(s.arena, header);
    try s.state.writeHeader(s.io, s.arena, s.header_lines);
    try s.state.writeTitles(s.io, explorer.table_titles);
    try plan.writeBuffer(s.arena, &writer.interface, header, s.entries);
    try writer.interface.flush();
    // O aviso ja esta no arquivo que sera aberto agora; a proxima navegacao
    // parte de uma tela limpa.
    s.notice = null;
    try writeTree(s);
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
    try w.print("{s}\n", .{abbreviateHome(s.arena, s.environ, s.base)});
    var options = s.options;
    options.recursive = true;
    var out: TreeWriter = .{ .writer = w };
    explorer.enumerate(s.arena, s.io, s.base, options, out.sink()) catch |err| {
        if (err != TreeWriter.LimitReached.TreeLimitReached) return err;
        try w.print("… arvore truncada em {d} entradas\n", .{TreeWriter.limit});
    };
    try w.flush();
}

fn changeDir(s: *Session, target: []const u8) !void {
    const joined = if (std.fs.path.isAbsolute(target))
        target
    else
        try std.fs.path.join(s.arena, &.{ s.base, target });

    const resolved = Io.Dir.cwd().realPathFileAlloc(s.io, joined, s.arena) catch {
        try report(s, try std.fmt.allocPrint(s.arena, "nao consegui entrar em {s}", .{target}));
        return;
    };
    const st = Io.Dir.cwd().statFile(s.io, resolved, .{}) catch {
        try report(s, try std.fmt.allocPrint(s.arena, "nao consegui entrar em {s}", .{target}));
        return;
    };
    if (st.kind != .directory) {
        try report(s, try std.fmt.allocPrint(s.arena, "{s} nao e um diretorio", .{target}));
        return;
    }
    s.base = resolved;
    try s.history.push(s.arena, resolved);
    try loadListing(s);
}

fn goBack(s: *Session) !void {
    const target = s.history.back() orelse {
        s.notice = "nao ha para onde voltar nesta sessao";
        return;
    };
    if (!try enterVisited(s, target)) _ = s.history.forward();
}

fn goForward(s: *Session) !void {
    const target = s.history.forward() orelse {
        s.notice = "nao ha para onde avancar nesta sessao";
        return;
    };
    if (!try enterVisited(s, target)) _ = s.history.back();
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
    s.base = target;
    try loadListing(s);
    return true;
}

fn openFileInEditor(s: *Session, target: []const u8) !void {
    const editor = editor_mod.resolve(s.arena, s.io, s.environ, s.editor_spec) catch |err| {
        try explainEditor(s.out, err);
        return;
    };
    _ = editor_mod.run(
        s.arena,
        s.io,
        editor,
        s.environ,
        target,
        s.base,
        null,
    ) catch |err| {
        try s.out.print("lst-f: falha ao abrir arquivo no editor: {s}\n", .{@errorName(err)});
    };
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

    fn emit(ctx: *anyopaque, index: u32, e: explorer.Entry) anyerror!void {
        const f: *Feed = @ptrCast(@alignCast(ctx));
        if (e.parent) return;
        try f.paths.append(f.arena, e);
        // Campo 1 e o indice, nunca o caminho: nome de arquivo pode conter TAB.
        try f.records.print("{d}\t", .{index});
        try explorer.writeDisplay(f.records, e, f.options);
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
        try report(s, "o fzf nao esta disponivel; a busca depende dele");
        return false;
    }

    try s.state.writeBase(s.io, s.base);

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
    explorer.enumerate(s.arena, s.io, s.base, options, feed.sink()) catch {};
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
            .id = index,
            .path = e.path,
            .kind = e.kind,
            .display = display.written(),
        });
    }
    if (entries.items.len == 0 and unlistable.items.len == 0) return false;

    s.entries = try entries.toOwnedSlice(s.arena);
    s.unlistable = try unlistable.toOwnedSlice(s.arena);
    s.scope = if (query.len > 0)
        try std.fmt.allocPrint(s.arena, "resultado de :find {s} ({d} marcada(s))", .{ query, s.entries.len })
    else
        try std.fmt.allocPrint(s.arena, "resultado de :find ({d} marcada(s))", .{s.entries.len});
    return true;
}

fn findHeader(s: *Session) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(s.arena);
    const w = &buf.writer;
    const width: usize = @max(40, terminalWidth() -| gutter);

    const location = try std.fmt.allocPrint(s.arena, "{s}  [arvore]{s}", .{
        abbreviateHome(s.arena, s.environ, s.base),
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

    try explorer.writeColumnTitles(w, s.options);
    try w.writeByte('\n');
    try w.splatBytesAll("\u{2500}", width);
    return buf.written();
}

/// Colunas que o fzf consome a esquerda do texto (ponteiro e marcador).
const gutter = 4;

fn terminalWidth() usize {
    if (@import("builtin").os.tag != .linux) return 80;
    const linux = std.os.linux;
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

/// `$HOME` vira `~`, como na barra de localizacao de qualquer gerenciador de
/// arquivos. So encurta a exibicao; o caminho real nunca passa por aqui.
/// abbreviateHome(arena: Allocator, environ: *const std.process.Environ.Map, path: []const u8) []const u8 {
// const home = environ.get("HOME") orelse return path;
// if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return path;
// if (path.len != home.len and path[home.len] != '/') return path;
// return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]}) catch path;
// }

fn abbreviateHome(_: Allocator, _: *const std.process.Environ.Map, path: []const u8) []const u8 {
    return path;
}

// ---------------------------------------------------------------------------
// Aplicacao
// ---------------------------------------------------------------------------

fn openBase(s: *Session) !Io.Dir {
    return Io.Dir.cwd().openDir(s.io, s.base, .{ .iterate = true });
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

/// `false` quando o usuario recusou tudo ou a aplicacao falhou.
fn confirmAndApply(s: *Session, p: plan.Plan, approved_in_editor: bool) !bool {
    var base_dir = try openBase(s);
    defer base_dir.close(s.io);

    const missing = try missingDirs(s, base_dir, p.mkdirs);
    try renderDiff(s, base_dir, p, missing);

    var effective = p;
    effective.mkdirs = missing;

    if (!approved_in_editor and (p.moves.len > 0 or p.creates.len > 0 or missing.len > 0)) {
        const question = if (p.moves.len == 0)
            "Apply creations?"
        else if (p.creates.len == 0)
            "Apply renames and moves?"
        else
            "Apply creations, renames, and moves?";
        if (!try confirm(s, question)) {
            effective.moves = &.{};
            effective.renames = &.{};
            effective.mkdirs = &.{};
            effective.creates = &.{};
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
        if (area_ptr == null) effective.removes = &.{};
    }

    if (effective.isEmpty()) {
        try report(s, "nada foi aplicado");
        return false;
    }

    const outcome = try fsops.apply(s.arena, s.io, base_dir, effective, area_ptr);
    if (outcome.failure) |failure| {
        // Em falha, o relatorio precisa permanecer visivel antes de voltar ao
        // editor para que o estado e a recuperacao manual fiquem claros.
        _ = failure;
        try reportOutcome(s, outcome);
        try pause(s);
        return false;
    }

    if (!outcome.applied.isEmpty()) {
        s.undo = .{
            .base = s.base,
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
    var created: usize = 0;
    for (applied.created) |c| {
        if (c.implicit) parents += 1 else created += 1;
    }

    var parts: std.ArrayList([]const u8) = .empty;
    if (created > 0) {
        try parts.append(s.arena, try std.fmt.allocPrint(s.arena, "{d} criado(s)", .{created}));
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
    const w = s.out;
    try w.writeAll("\n");

    var asked: usize = 0;
    for (p.creates) |c| {
        if (!c.implicit) asked += 1;
    }
    if (asked > 0) {
        try w.print("Create ({d}):\n", .{asked});
        for (p.creates) |c| {
            try w.print("  {s}{s}{s}\n", .{
                c.path,
                if (c.kind == .dir) "/" else "",
                if (c.implicit) "  (parent directory)" else "",
            });
        }
        try w.writeAll("\n");
    }

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
        try w.print("\nFALHA em \"{s}\": {s} ({s})\n", .{ f.phase, f.detail, @errorName(f.err) });
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
            for (outcome.applied.removed) |rm| {
                try w.print("  {s} esta em {s}/{s}\n", .{ rm.path, outcome.applied.area orelse "?", rm.stored });
            }
        }
        return;
    }

    try w.print(
        "\nAplicado: {d} criacao(oes), {d} renomeacao(oes), {d} diretorio(s)-pai, {d} remocao(oes).\n",
        .{
            outcome.applied.created.len,
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

fn ensureArea(s: *Session) !*fsops.Area {
    if (s.area != null and std.mem.eql(u8, s.area_base, s.base)) return &s.area.?;
    if (s.area) |*a| {
        a.close(s.io);
        s.area = null;
    }

    var base_dir = try openBase(s);
    defer base_dir.close(s.io);

    const name = try fsops.areaName(s.arena, s.pid);
    s.area = try fsops.openArea(s.arena, s.io, base_dir, name);
    s.area_base = s.base;

    for (s.areas.items) |a| {
        if (std.mem.eql(u8, a.base, s.base)) return &s.area.?;
    }
    try s.areas.append(s.arena, .{ .base = s.base, .name = name });
    return &s.area.?;
}

fn undoLast(s: *Session) !void {
    const u = s.undo orelse {
        try report(s, "nada para desfazer nesta sessao");
        return;
    };

    var base_dir = Io.Dir.cwd().openDir(s.io, u.base, .{ .iterate = true }) catch {
        try report(s, "o diretorio da ultima operacao nao esta mais acessivel");
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
        s.undo = null;
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
    if (s.area) |*a| {
        a.close(s.io);
        s.area = null;
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

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

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
