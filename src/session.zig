//! Estado compartilhado entre o processo principal e o self-exec de preview
//! que o fzf dispara (`--preview-index`).
//!
//! Nao confundir com a **lixeira** do `fsops`: aquela e `~/.local/share/lst-f/`
//! `trash`, sobrevive a sessao e existe para a remocao ser recuperavel. Esta
//! aqui e um diretorio de trabalho volatil, e existe so para que
//! nenhum caminho precise ser interpolado em linha de comando de shell: os
//! filhos recebem o caminho deste diretorio pela variavel `LST_F_STATE`.

const std = @import("std");
const explorer = @import("explorer.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const env_state = "LST_F_STATE";
pub const env_self = "LST_F_SELF";
pub const env_location = "LST_F_LOCATION";
/// Caminho da lixeira, para o `:trash` do helper. Fixo na sessao, entao vai por
/// ambiente e nao por arquivo de estado.
pub const env_trash = "LST_F_TRASH";

const helper_template = @embedFile("vim/helper.vim");

/// Diretorios visitados na sessao, no modelo de navegador: `back` e `forward`
/// andam sobre o que ja foi visitado, e entrar em um diretorio novo depois de
/// ter voltado descarta o caminho que estava a frente.
pub const History = struct {
    items: std.ArrayList([]const u8) = .empty,
    pos: usize = 0,

    /// Registra a chegada em `path`. Ficar onde ja se esta nao empilha, senao
    /// um `:refresh` ou um `:cd .` encheriam o historico de repeticoes.
    pub fn push(h: *History, arena: Allocator, path: []const u8) Allocator.Error!void {
        if (h.items.items.len == 0) {
            try h.items.append(arena, path);
            h.pos = 0;
            return;
        }
        if (std.mem.eql(u8, h.items.items[h.pos], path)) return;
        h.items.shrinkRetainingCapacity(h.pos + 1);
        try h.items.append(arena, path);
        h.pos = h.items.items.len - 1;
    }

    /// Copia independente do trilho. Um View novo herda o trilho de quem o
    /// abriu, mas nao pode compartilhar o array: um `push` de um lado
    /// descartaria o `forward` do outro.
    pub fn clone(h: *const History, arena: Allocator) Allocator.Error!History {
        const items = try arena.dupe([]const u8, h.items.items);
        return .{ .items = .fromOwnedSlice(items), .pos = h.pos };
    }

    /// `null` na ponta: nao ha para onde ir, e a posicao nao se mexe.
    pub fn back(h: *History) ?[]const u8 {
        if (h.pos == 0) return null;
        h.pos -= 1;
        return h.items.items[h.pos];
    }

    pub fn forward(h: *History) ?[]const u8 {
        if (h.pos + 1 >= h.items.items.len) return null;
        h.pos += 1;
        return h.items.items[h.pos];
    }
};

pub const State = struct {
    path: []const u8,
    dir: Io.Dir,

    /// Cria um diretorio de estado privado (0700) preferindo `$XDG_RUNTIME_DIR`.
    /// Falha em `PathAlreadyExists` (tenta outro sufixo aleatorio) e verifica dono
    /// e modo via `fstat`, fechando ataques de pre-criacao em `/tmp` compartilhado.
    pub fn create(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, pid: std.posix.pid_t) !State {
        const base = blk: {
            if (environ.get("XDG_RUNTIME_DIR")) |xdg| {
                if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) break :blk xdg;
            }
            break :blk environ.get("TMPDIR") orelse "/tmp";
        };
        const only_user: Io.File.Permissions = @enumFromInt(0o700);
        const now_ns: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.now(.real, io).toNanoseconds())));
        var prng = std.Random.DefaultPrng.init(now_ns ^ @as(u64, @intCast(pid)));
        const rand = prng.random();

        var attempt: usize = 0;
        while (attempt < 16) : (attempt += 1) {
            const token = rand.int(u64);
            const path = try std.fmt.allocPrint(arena, "{s}/lst-f-{d}-{x:0>8}", .{ base, pid, @as(u32, @truncate(token)) });
            Io.Dir.cwd().createDir(io, path, only_user) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
                Io.Dir.cwd().deleteTree(io, path) catch {};
                return err;
            };
            if (!verifyPrivateDir(dir.handle)) {
                dir.close(io);
                return error.UnsafeStateDir;
            }
            return .{ .path = path, .dir = dir };
        }
        return error.PathAlreadyExists;
    }

    fn verifyPrivateDir(fd: std.posix.fd_t) bool {
        if (@import("builtin").os.tag != .linux) return true;
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true }, &stx);
        if (linux.errno(rc) != .SUCCESS) return false;
        if ((stx.mode & linux.S.IFMT) != linux.S.IFDIR) return false;
        if (stx.uid != linux.getuid()) return false;
        if ((stx.mode & 0o077) != 0) return false;
        return true;
    }

    pub fn open(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) !State {
        const path = environ.get(env_state) orelse return error.NoSessionState;
        const owned = try arena.dupe(u8, path);
        const dir = try Io.Dir.cwd().openDir(io, owned, .{ .iterate = true });
        return .{ .path = owned, .dir = dir };
    }

    pub fn destroy(s: *State, io: Io) void {
        s.dir.close(io);
        Io.Dir.cwd().deleteTree(io, s.path) catch {};
    }

    pub fn writeBase(s: State, io: Io, base: []const u8) !void {
        try s.dir.writeFile(io, .{ .sub_path = "base", .data = base });
    }

    pub fn readBase(s: State, io: Io, arena: Allocator) ![]const u8 {
        return s.dir.readFileAlloc(io, "base", arena, .limited(Io.Dir.max_path_bytes));
    }

    /// A lista corrente, um caminho por registro, separada por NUL. E o que
    /// resolve o indice do campo 1 do fzf de volta para o caminho, tanto no
    /// processo principal quanto no filho de preview.
    pub fn listFile(s: State, io: Io) !Io.File {
        return s.dir.createFile(io, "list", .{ .truncate = true });
    }

    /// Aviso de uma operacao concluida. Vai para a barra de baixo, nao para o
    /// buffer: linha de aviso empurrava a lista para baixo, separando-a da
    /// barra de titulos.
    pub fn writeNotice(s: State, io: Io, text: []const u8) !void {
        try s.dir.writeFile(io, .{ .sub_path = "notice", .data = text });
    }

    /// Titulos das colunas, desenhados pelo helper na barra de topo.
    pub fn writeTitles(s: State, io: Io, titles: []const u8) !void {
        try s.dir.writeFile(io, .{ .sub_path = "titles", .data = titles });
    }

    /// As linhas de cabecalho do buffer aberto. O helper Vim as usa para
    /// recompor a barra de titulo se uma tecla a apagar ou deslocar.
    pub fn writeHeader(s: State, io: Io, arena: Allocator, lines: []const []const u8) !void {
        const joined = try std.mem.join(arena, "\n", lines);
        try s.dir.writeFile(io, .{ .sub_path = "header", .data = joined });
    }

    /// O helper do Vim grava este sinal depois de o usuario aprovar uma
    /// alteracao no proprio editor. Ler tambem o remove, para que uma
    /// aprovacao nunca vaze para a proxima tela.
    pub fn takeApproval(s: State, io: Io) bool {
        s.dir.deleteFile(io, "approved") catch return false;
        return true;
    }

    pub fn clearApproval(s: State, io: Io) void {
        s.dir.deleteFile(io, "approved") catch {};
    }

    /// Arvore visual da listagem local. E consumida somente pelo helper Vim;
    /// nao participa do plano de operacoes nem e um plugin persistente.
    pub fn treeFile(s: State, io: Io) !Io.File {
        return s.dir.createFile(io, "tree", .{ .truncate = true });
    }

    pub fn readList(s: State, io: Io, arena: Allocator) ![]const []const u8 {
        const raw = s.dir.readFileAlloc(io, "list", arena, .limited(64 * 1024 * 1024)) catch return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, raw, 0);
        while (it.next()) |item| {
            if (item.len == 0) continue;
            try out.append(arena, item);
        }
        return out.toOwnedSlice(arena);
    }

    pub fn writeHelperScript(s: State, io: Io, app_name: []const u8, version: []const u8) !void {
        return s.writeHelperScriptWithOptions(io, app_name, version, true);
    }

    pub fn writeHelperScriptWithOptions(
        s: State,
        io: Io,
        app_name: []const u8,
        version: []const u8,
        icons: bool,
    ) !void {
        var file = try s.dir.createFile(io, "helper.vim", .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer: Io.File.Writer = .init(file, io, &buffer);
        const w = &writer.interface;

        var id_buf: [128]u8 = undefined;
        const identity = std.fmt.bufPrint(&id_buf, "{s} v{s}", .{ app_name, version }) catch "lst-f";
        const icons_val: []const u8 = if (icons) "1" else "0";

        var rest: []const u8 = helper_template;
        while (rest.len > 0) {
            const idx = std.mem.indexOf(u8, rest, "{{") orelse {
                try w.writeAll(rest);
                break;
            };
            try w.writeAll(rest[0..idx]);
            rest = rest[idx..];
            if (std.mem.startsWith(u8, rest, "{{IDENTITY}}")) {
                try w.writeAll(identity);
                rest = rest["{{IDENTITY}}".len..];
            } else if (std.mem.startsWith(u8, rest, "{{ICONS}}")) {
                try w.writeAll(icons_val);
                rest = rest["{{ICONS}}".len..];
            } else if (std.mem.startsWith(u8, rest, "{{ICON_HIGHLIGHTS_LIGHT}}")) {
                try w.writeAll(comptime explorer.vimIconHighlightsLight());
                rest = rest["{{ICON_HIGHLIGHTS_LIGHT}}".len..];
            } else if (std.mem.startsWith(u8, rest, "{{ICON_HIGHLIGHTS_DARK}}")) {
                try w.writeAll(comptime explorer.vimIconHighlightsDark());
                rest = rest["{{ICON_HIGHLIGHTS_DARK}}".len..];
            } else if (std.mem.startsWith(u8, rest, "{{ICON_SYNTAX}}")) {
                try w.writeAll(comptime explorer.vimIconSyntax());
                rest = rest["{{ICON_SYNTAX}}".len..];
            } else {
                try w.writeAll("{{");
                rest = rest[2..];
            }
        }
        try w.flush();
    }
};
