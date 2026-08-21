//! Parsing de argumentos e composicao do fluxo.

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
    reload_toggle,
    help,
    version,
};

pub const Browse = struct {
    dir: []const u8 = ".",
    editor: ?[]const u8 = null,
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
        if (std.mem.eql(u8, arg, "--reload-toggle")) return .reload_toggle;
        if (std.mem.eql(u8, arg, "--preview-index")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            return .{ .preview_index = std.fmt.parseInt(u32, args[i], 10) catch return error.BadValue };
        }
        if (std.mem.eql(u8, arg, "--icons")) {
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
        \\{s} {s} -- explora e altera o filesystem no terminal
        \\
        \\uso: lst-f [opcoes] [diretorio]
        \\
        \\  --editor <cmd>     editor a usar (padrao: $VISUAL, $EDITOR)
        \\  --max-depth <n>    profundidade maxima da busca recursiva
        \\  --icons            emite icones na lista
        \\  --no-color         desliga as cores
        \\  -h, --help         esta ajuda
        \\  -V, --version      versao
        \\
        \\teclas na lista:
        \\  Enter              abre o arquivo ou entra no diretorio
        \\  Tab                marca / desmarca
        \\  {s}             alterna entre listar o diretorio e buscar na arvore
        \\  {s}             envia a marcacao para o editor
        \\  {s}              desfaz a ultima operacao aplicada nesta sessao
        \\  Esc                sai
        \\
        \\Precisa do fzf ({d}.{d}+) e de um Vim ou Neovim no PATH.
        \\
    , .{
        build_options.app_name,
        build_options.version,
        fzf.Keys.recursive,
        fzf.Keys.edit,
        fzf.Keys.undo,
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
            try out.print("{s} {s}\n", .{ build_options.app_name, build_options.version });
            break :blk 0;
        },
        .preview_index => |index| runPreview(arena, io, out, environ, index),
        .reload_toggle => runReloadToggle(arena, io, out, environ),
        .browse => |b| runBrowse(arena, io, out, environ, b),
    };
}

// ---------------------------------------------------------------------------
// Self-exec disparados pelo fzf
// ---------------------------------------------------------------------------

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

/// Alterna listagem local e busca recursiva sem sair do fzf. So e usado quando
/// o `reload` esta disponivel; sem ele, a tecla vira `--expect` e o processo
/// principal respawna o fzf com a outra lista.
fn runReloadToggle(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *const std.process.Environ.Map,
) !u8 {
    const state = session.State.open(arena, io, environ) catch return 1;
    const base_path = state.readBase(io, arena) catch return 1;
    const mode = (state.readMode(io, arena) catch session.Mode.local).toggle();
    try state.writeMode(io, mode);

    var options: explorer.Options = .{ .recursive = mode == .recursive };
    options.color = environ.get("NO_COLOR") == null;

    var list_file = try state.listFile(io);
    defer list_file.close(io);
    var list_buffer: [64 * 1024]u8 = undefined;
    var list_writer: Io.File.Writer = .init(list_file, io, &list_buffer);

    var feed: Feed = .{ .records = out, .list = &list_writer.interface, .options = options };
    explorer.enumerate(arena, io, base_path, options, feed.sink()) catch {};
    try list_writer.interface.flush();
    return 0;
}

const Feed = struct {
    records: *Io.Writer,
    list: *Io.Writer,
    options: explorer.Options,

    fn emit(ctx: *anyopaque, index: u32, e: explorer.Entry) anyerror!void {
        const f: *Feed = @ptrCast(@alignCast(ctx));
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

// ---------------------------------------------------------------------------
// Sessao interativa
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

const Browser = struct {
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

    base: []const u8,
    mode: session.Mode = .local,

    area: ?fsops.Area = null,
    area_base: []const u8 = "",
    areas: std.ArrayList(AreaRef) = .empty,
    undo: ?Undo = null,
};

fn runBrowse(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    opts: Browse,
) !u8 {
    const features = fzf.detect(arena, io) catch |err| {
        switch (err) {
            error.FzfNotFound => try out.writeAll(
                "lst-f: o fzf nao esta no PATH. Instale-o pelo gerenciador da distribuicao.\n",
            ),
            error.FzfTooOld => try out.print(
                "lst-f: fzf antigo demais; o piso e {d}.{d} (--preview).\n",
                .{ fzf.min_version.major, fzf.min_version.minor },
            ),
            else => try out.print("lst-f: nao foi possivel usar o fzf ({s}).\n", .{@errorName(err)}),
        }
        try out.flush();
        return 1;
    };

    const base = Io.Dir.cwd().realPathFileAlloc(io, opts.dir, arena) catch {
        try out.print("lst-f: nao foi possivel abrir {s}\n", .{opts.dir});
        return 1;
    };

    const pid = std.os.linux.getpid();
    var state = try session.State.create(arena, io, environ, pid);
    defer state.destroy(io);

    try environ.put(session.env_state, state.path);
    try environ.put(session.env_self, try selfPath(arena, io, environ));
    // O contrato com o fzf depende de flags exatas, e `FZF_DEFAULT_OPTS` entra
    // antes delas. Uma configuracao pessoal comum como
    // `--preview-window hidden` ja desliga o preview do lst-f, e um
    // `--bind ...execute(rm -i {})` receberia o registro inteiro no lugar de um
    // caminho. Para esta invocacao, o ambiente do fzf comeca limpo.
    try environ.put("FZF_DEFAULT_OPTS", "");
    try environ.put("FZF_DEFAULT_OPTS_FILE", "");

    if (editor_mod.resolve(arena, environ, opts.editor)) |_| {} else |err| {
        try explainEditor(out, err);
    }

    var b: Browser = .{
        .arena = arena,
        .io = io,
        .out = out,
        .environ = environ,
        .tty = Tty.open(arena, io),
        .options = opts.options,
        .editor_spec = opts.editor,
        .features = features,
        .state = state,
        .pid = pid,
        .base = base,
    };
    defer cleanupAreas(&b);

    try loop(&b);
    return 0;
}

fn loop(b: *Browser) !void {
    while (true) {
        b.options.recursive = b.mode == .recursive;
        try b.state.writeBase(b.io, b.base);
        try b.state.writeMode(b.io, b.mode);

        const orphans = fsops.scanOrphans(b.arena, b.io, try openBase(b), b.pid) catch &.{};
        const header = try buildHeader(b, orphans);

        var runner = try fzf.start(b.arena, b.io, .{
            .features = b.features,
            .header = header,
            .prompt = "> ",
            .environ = b.environ,
            .color = b.options.color,
            .preview = true,
        });

        var list_file = try b.state.listFile(b.io);
        var list_buffer: [64 * 1024]u8 = undefined;
        var list_writer: Io.File.Writer = .init(list_file, b.io, &list_buffer);

        var feed: Feed = .{
            .records = runner.writer(),
            .list = &list_writer.interface,
            .options = b.options,
        };
        // Streaming: o fzf ja mostra as primeiras entradas enquanto a arvore
        // ainda esta sendo percorrida.
        explorer.enumerate(b.arena, b.io, b.base, b.options, feed.sink()) catch {};
        list_writer.interface.flush() catch {};
        list_file.close(b.io);

        const selection = try runner.finish(b.arena);
        if (selection.aborted) return;

        // Um `reload` dentro do fzf pode ter trocado o modo e a lista.
        b.mode = b.state.readMode(b.io, b.arena) catch b.mode;
        const paths = try b.state.readList(b.io, b.arena);

        if (std.mem.eql(u8, selection.key, fzf.Keys.recursive)) {
            b.mode = b.mode.toggle();
            continue;
        }
        if (std.mem.eql(u8, selection.key, fzf.Keys.undo)) {
            try undoLast(b);
            continue;
        }
        if (std.mem.eql(u8, selection.key, fzf.Keys.edit)) {
            try editSelection(b, paths, selection.indices);
            continue;
        }
        if (selection.indices.len == 0) return;
        if (!try openOrEnter(b, paths, selection.indices[0])) return;
    }
}

fn openBase(b: *Browser) !Io.Dir {
    return Io.Dir.cwd().openDir(b.io, b.base, .{ .iterate = true });
}

fn buildHeader(b: *Browser, orphans: []const fsops.Orphan) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(b.arena);
    const w = &buf.writer;
    try w.print("{s}{s}\n", .{ b.base, if (b.mode == .recursive) "  [arvore]" else "" });
    try w.print(
        "Enter abre  Tab marca  {s} arvore  {s} editar  {s} desfazer",
        .{ fzf.Keys.recursive, fzf.Keys.edit, fzf.Keys.undo },
    );
    for (orphans) |o| {
        try w.print(
            "\narea orfa {s} ({d} item(ns)) do PID {d}, que nao esta mais rodando",
            .{ o.name, o.items, o.pid },
        );
    }
    return buf.written();
}

/// `true` para continuar a sessao.
fn openOrEnter(b: *Browser, paths: []const []const u8, index: u32) !bool {
    if (index >= paths.len) return true;
    const rel = paths[index];

    if (std.mem.eql(u8, rel, "..")) {
        b.base = std.fs.path.dirname(b.base) orelse b.base;
        b.mode = .local;
        return true;
    }

    var base_dir = try openBase(b);
    defer base_dir.close(b.io);

    const st = base_dir.statFile(b.io, rel, .{}) catch {
        try report(b, "nao foi possivel abrir a entrada");
        return true;
    };
    if (st.kind == .directory) {
        b.base = try std.fs.path.join(b.arena, &.{ b.base, rel });
        b.mode = .local;
        return true;
    }

    const editor = editor_mod.resolve(b.arena, b.environ, b.editor_spec) catch |err| {
        try explainEditor(b.out, err);
        try pause(b);
        return true;
    };
    const full = try std.fs.path.join(b.arena, &.{ b.base, rel });
    _ = editor_mod.run(b.arena, b.io, editor, b.environ, full) catch |err| {
        try b.out.print("lst-f: falha ao abrir o editor: {s}\n", .{@errorName(err)});
        try pause(b);
    };
    return true;
}

// ---------------------------------------------------------------------------
// Fluxo de edicao
// ---------------------------------------------------------------------------

fn editSelection(b: *Browser, paths: []const []const u8, indices: []const u32) !void {
    if (indices.len == 0) return;

    var base_dir = try openBase(b);
    defer base_dir.close(b.io);

    var originals: std.ArrayList(plan.Original) = .empty;
    for (indices) |index| {
        if (index >= paths.len) continue;
        const rel = paths[index];
        if (std.mem.eql(u8, rel, "..")) continue;
        // O Vim nao preserva bytes invalidos no round-trip: o ID estaria certo
        // e o destino, corrompido. Melhor recusar nomeando a entrada.
        if (!std.unicode.utf8ValidateSlice(rel)) {
            try b.out.print(
                "lst-f: a entrada \"{s}\" nao tem nome UTF-8 valido e nao pode ir para o editor.\n",
                .{rel},
            );
            try pause(b);
            return;
        }
        const st = base_dir.statFile(b.io, rel, .{ .follow_symlinks = false }) catch continue;
        try originals.append(b.arena, .{
            .id = index,
            .path = rel,
            .kind = switch (st.kind) {
                .directory => .dir,
                .file, .sym_link => .file,
                else => .other,
            },
        });
    }
    if (originals.items.len == 0) {
        try report(b, "nada selecionado para editar");
        return;
    }

    // Sufixo proprio: o buffer fica identificavel no editor e nao casa com
    // autocmd de formatacao presa a extensao (*.txt, *.md). Nao ha tentativa de
    // neutralizar a configuracao do usuario -- usar o editor dele e o ponto;
    // quem quiser isolamento passa `--editor "vim -u NONE"`. A garantia contra
    // um plugin que reformate o buffer e o diff, que mostra tudo antes de gravar.
    const buffer_path = try std.fmt.allocPrint(b.arena, "{s}/lst-f-edit.lstf", .{b.state.path});
    {
        var file = try Io.Dir.cwd().createFile(b.io, buffer_path, .{ .truncate = true });
        defer file.close(b.io);
        var buf: [64 * 1024]u8 = undefined;
        var fw: Io.File.Writer = .init(file, b.io, &buf);
        try plan.writeBuffer(&fw.interface, b.base, originals.items);
        try fw.interface.flush();
    }

    const editor = editor_mod.resolve(b.arena, b.environ, b.editor_spec) catch |err| {
        try explainEditor(b.out, err);
        try pause(b);
        return;
    };
    const result = editor_mod.run(b.arena, b.io, editor, b.environ, buffer_path) catch |err| {
        try b.out.print("lst-f: falha ao abrir o editor: {s}\n", .{@errorName(err)});
        try pause(b);
        return;
    };
    if (result == .aborted) {
        try report(b, "editor saiu com erro: nada foi aplicado");
        return;
    }

    const text = try Io.Dir.cwd().readFileAlloc(b.io, buffer_path, b.arena, .limited(64 * 1024 * 1024));
    const parsed = try plan.parseBuffer(b.arena, text);
    switch (parsed) {
        .invalid => |problems| return reportProblems(b, problems),
        .ok => {},
    }

    const built = try plan.build(b.arena, originals.items, parsed.ok, .{
        .temp_prefix = try std.fmt.allocPrint(b.arena, ".lst-f-tmp-{d}-", .{b.pid}),
    });
    switch (built) {
        .invalid => |problems| return reportProblems(b, problems),
        .ok => {},
    }

    try confirmAndApply(b, base_dir, built.ok);
}

fn confirmAndApply(b: *Browser, base_dir: Io.Dir, p: plan.Plan) !void {
    if (p.isEmpty()) {
        try report(b, "nada mudou no buffer");
        return;
    }

    const missing = try missingDirs(b, base_dir, p.mkdirs);
    try renderDiff(b, base_dir, p, missing);

    var effective = p;
    effective.mkdirs = missing;

    if (p.moves.len > 0 or missing.len > 0) {
        if (!try confirm(b, "Aplicar renomeacoes e movimentos?")) return;
    }

    var area_ptr: ?*fsops.Area = null;
    if (p.removes.len > 0) {
        if (try confirm(b, "Confirmar as remocoes?")) {
            area_ptr = ensureArea(b) catch |err| blk: {
                if (err == error.AreaUnavailable) {
                    try b.out.writeAll(
                        "lst-f: sem permissao de escrita no diretorio-base: nao da para criar a\n" ++
                            "       area de sessao, logo nao ha como garantir o rollback. As remocoes\n" ++
                            "       foram recusadas; as renomeacoes seguem.\n",
                    );
                } else {
                    try b.out.print("lst-f: nao foi possivel abrir a area de sessao: {s}\n", .{@errorName(err)});
                }
                break :blk null;
            };
        }
        if (area_ptr == null) effective.removes = &.{};
    }

    if (effective.isEmpty()) {
        try report(b, "nada a aplicar");
        return;
    }

    const outcome = try fsops.apply(b.arena, b.io, base_dir, effective, area_ptr);
    try reportOutcome(b, outcome);

    if (outcome.failure == null and !outcome.applied.isEmpty()) {
        b.undo = .{
            .base = b.base,
            .area = if (area_ptr) |a| a.name else null,
            .applied = outcome.applied,
        };
    }
    try pause(b);
}

fn missingDirs(b: *Browser, base_dir: Io.Dir, dirs: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (dirs) |d| {
        _ = base_dir.statFile(b.io, d, .{ .follow_symlinks = false }) catch {
            try out.append(b.arena, d);
            continue;
        };
    }
    return out.toOwnedSlice(b.arena);
}

fn renderDiff(b: *Browser, base_dir: Io.Dir, p: plan.Plan, missing: []const []const u8) !void {
    const w = b.out;
    try w.writeAll("\n");

    if (missing.len > 0) {
        try w.print("Criar diretorio ({d}):\n", .{missing.len});
        for (missing) |d| try w.print("  {s}/\n", .{d});
        try w.writeAll("\n");
    }

    if (p.moves.len > 0) {
        try w.print("Renomear ou mover ({d}):\n", .{p.moves.len});
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
            "Remover ({d})  ->  area da sessao .lst-f-{d}/, apagada ao sair: depois disso\n" ++
                "              a remocao e definitiva; isto nao e uma lixeira.\n",
            .{ p.removes.len, b.pid },
        );
        for (p.removes) |rm| {
            if (rm.kind == .dir) {
                const count = fsops.subtreeCount(b.io, base_dir, rm.path);
                try w.print("  {s}/  ({d} item(ns) na subarvore)\n", .{ rm.path, count });
            } else {
                try w.print("  {s}\n", .{rm.path});
            }
        }
        try w.writeAll("\n");
    }

    if (p.unchanged > 0) try w.print("{d} entrada(s) sem mudanca.\n\n", .{p.unchanged});
}

fn reportOutcome(b: *Browser, outcome: fsops.Outcome) !void {
    const w = b.out;
    if (outcome.failure) |f| {
        try w.print("\nFALHA em \"{s}\": {s} ({s})\n", .{ f.phase, f.detail, @errorName(f.err) });
        if (outcome.rollback_errors.len == 0) {
            try w.writeAll("Rollback completo: nada foi alterado.\n");
        } else {
            try w.writeAll(
                "O rollback nao conseguiu desfazer tudo. Estado a recuperar a mao:\n",
            );
            for (outcome.rollback_errors) |e| try w.print("  {s}\n", .{e});
            try w.writeAll("Entradas que continuam aplicadas:\n");
            for (outcome.applied.renames) |r| try w.print("  {s} -> {s}\n", .{ r.from, r.to });
            for (outcome.applied.removed) |rm| {
                try w.print("  {s} esta em {s}/{s}\n", .{ rm.path, outcome.applied.area orelse "?", rm.stored });
            }
        }
        return;
    }

    try w.print(
        "\nAplicado: {d} renomeacao(oes), {d} diretorio(s) criado(s), {d} remocao(oes).\n",
        .{ outcome.applied.renames.len, outcome.applied.created_dirs.len, outcome.applied.removed.len },
    );
    if (outcome.applied.removed.len > 0) {
        try w.print("Use {s} para desfazer enquanto a sessao estiver aberta.\n", .{fzf.Keys.undo});
    }
}

fn reportProblems(b: *Browser, problems: []const plan.Problem) !void {
    try b.out.writeAll("\nNada foi aplicado. O buffer editado tem problemas:\n");
    for (problems) |p| {
        try b.out.writeAll("  ");
        try p.describe(b.out);
        try b.out.writeByte('\n');
    }
    try pause(b);
}

// ---------------------------------------------------------------------------
// Area de sessao e undo
// ---------------------------------------------------------------------------

fn ensureArea(b: *Browser) !*fsops.Area {
    if (b.area != null and std.mem.eql(u8, b.area_base, b.base)) return &b.area.?;
    if (b.area) |*a| {
        a.close(b.io);
        b.area = null;
    }

    var base_dir = try openBase(b);
    defer base_dir.close(b.io);

    const name = try fsops.areaName(b.arena, b.pid);
    b.area = try fsops.openArea(b.arena, b.io, base_dir, name);
    b.area_base = b.base;

    for (b.areas.items) |a| {
        if (std.mem.eql(u8, a.base, b.base)) return &b.area.?;
    }
    try b.areas.append(b.arena, .{ .base = b.base, .name = name });
    return &b.area.?;
}

fn undoLast(b: *Browser) !void {
    const u = b.undo orelse {
        try report(b, "nada para desfazer nesta sessao");
        return;
    };

    var base_dir = Io.Dir.cwd().openDir(b.io, u.base, .{ .iterate = true }) catch {
        try report(b, "o diretorio da ultima operacao nao esta mais acessivel");
        return;
    };
    defer base_dir.close(b.io);

    var area_dir: ?Io.Dir = null;
    if (u.area) |name| {
        area_dir = base_dir.openDir(b.io, name, .{ .iterate = true }) catch null;
    }
    defer if (area_dir) |d| d.close(b.io);

    const errors = try fsops.revert(b.arena, b.io, base_dir, u.applied, area_dir);
    if (errors.len == 0) {
        try b.out.writeAll("\nUltima operacao desfeita.\n");
        b.undo = null;
    } else {
        try b.out.writeAll("\nO undo nao conseguiu desfazer tudo:\n");
        for (errors) |e| try b.out.print("  {s}\n", .{e});
    }
    try pause(b);
}

/// Saida limpa apaga as areas. A partir daqui a remocao e definitiva.
fn cleanupAreas(b: *Browser) void {
    if (b.area) |*a| {
        a.close(b.io);
        b.area = null;
    }
    for (b.areas.items) |a| {
        var base_dir = Io.Dir.cwd().openDir(b.io, a.base, .{ .iterate = true }) catch continue;
        defer base_dir.close(b.io);
        base_dir.deleteTree(b.io, a.name) catch {};
    }
}

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------

const Tty = struct {
    file: Io.File,
    reader: *Io.File.Reader,

    fn open(arena: Allocator, io: Io) ?Tty {
        const file = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_only }) catch return null;
        const buffer = arena.alloc(u8, 1024) catch return null;
        const reader = arena.create(Io.File.Reader) catch return null;
        reader.* = .initStreaming(file, io, buffer);
        return .{ .file = file, .reader = reader };
    }

    fn line(t: Tty) ?[]const u8 {
        return t.reader.interface.takeDelimiterExclusive('\n') catch null;
    }
};

fn confirm(b: *Browser, question: []const u8) !bool {
    const tty = b.tty orelse return false;
    try b.out.print("{s} [s/N] ", .{question});
    try b.out.flush();
    const answer = tty.line() orelse return false;
    const trimmed = std.mem.trim(u8, answer, " \t\r");
    return trimmed.len > 0 and (trimmed[0] == 's' or trimmed[0] == 'S' or
        trimmed[0] == 'y' or trimmed[0] == 'Y');
}

fn pause(b: *Browser) !void {
    const tty = b.tty orelse return;
    try b.out.writeAll("\n[Enter para voltar a lista] ");
    try b.out.flush();
    _ = tty.line();
}

fn report(b: *Browser, message: []const u8) !void {
    try b.out.print("\nlst-f: {s}\n", .{message});
    try pause(b);
}

fn explainEditor(w: *Io.Writer, err: editor_mod.ResolveError) !void {
    switch (err) {
        error.NoEditor => try w.writeAll(
            "lst-f: nenhum editor configurado. Defina $VISUAL ou $EDITOR (por exemplo\n" ++
                "       export EDITOR=vim) ou use --editor. A navegacao e o preview seguem\n" ++
                "       funcionando sem editor.\n",
        ),
        error.NotForeground => try w.writeAll(
            "lst-f: o editor configurado nao segura o terminal e devolveria o controle\n" ++
                "       antes da edicao. Use um editor de terminal, ou a flag de espera do seu\n" ++
                "       (code --wait, subl -w).\n",
        ),
    }
}

fn selfPath(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) ![]const u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().readLink(io, "/proc/self/exe", &buf)) |n| {
        return arena.dupe(u8, buf[0..n]);
    } else |_| {}
    return editor_mod.which(arena, io, environ, "lst-f") orelse "lst-f";
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
    try testing.expect(try parse(a, &.{ "lst-f", "--reload-toggle" }) == .reload_toggle);
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

test "recursivo nao e flag de linha de comando" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    // A busca recursiva e um atalho dentro da sessao: exigir decidir antes de
    // abrir seria pior, porque o que se quer so aparece navegando.
    try testing.expectError(error.UnknownOption, parse(arena_state.allocator(), &.{ "lst-f", "--recursive" }));
}
