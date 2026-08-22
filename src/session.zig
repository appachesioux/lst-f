//! Estado compartilhado entre o processo principal e o self-exec de preview
//! que o fzf dispara (`--preview-index`).
//!
//! Nao confundir com a **area de sessao** do `fsops`: aquela e `.lst-f-<pid>/`
//! no diretorio-base, no mesmo filesystem, e existe para o rollback da
//! remocao. Esta aqui e um diretorio de trabalho volatil, e existe so para que
//! nenhum caminho precise ser interpolado em linha de comando de shell: os
//! filhos recebem o caminho deste diretorio pela variavel `LST_F_STATE`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const env_state = "LST_F_STATE";
pub const env_self = "LST_F_SELF";

pub const State = struct {
    path: []const u8,
    dir: Io.Dir,

    pub fn create(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, pid: std.posix.pid_t) !State {
        const tmp = environ.get("TMPDIR") orelse "/tmp";
        const path = try std.fmt.allocPrint(arena, "{s}/lst-f-{d}", .{ tmp, pid });
        Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        return .{ .path = path, .dir = dir };
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
        var file = try s.dir.createFile(io, "helper.vim", .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer: Io.File.Writer = .init(file, io, &buffer);
        const w = &writer.interface;

        try w.writeAll(
            \\set nocompatible
            \\function! LstfHelp() abort
            \\  let l:title = ' 
        );
        try w.print("{s} v{s}", .{ app_name, version });
        try w.writeAll(
            \\ — Ajuda (F1) '
            \\  let l:lines = [
            \\    \ '',
            \\    \ '  • Edite o caminho : renomeia ou move (cria os pais que faltarem)',
            \\    \ '  • Apague a linha  : remove a entrada (area de sessao temporaria)',
            \\    \ '  • ID de 4 digitos : vincula a linha (:sort e reordenar sao seguros)',
            \\    \ '',
            \\    \ '  Diretivas (escreva no buffer e salve):',
            \\    \ '    :cd <dir>      Entra no diretorio (.. sobe)',
            \\    \ '    :find [termo]  Busca recursiva fuzzy na arvore com fzf',
            \\    \ '    :undo          Desfaz a ultima operacao aplicada na sessao',
            \\    \ '    :quit          Sai da sessao (:cq aborta sem aplicar nada)',
            \\    \ '',
            \\    \ '  Atalhos no buffer:',
            \\    \ '    q              Sai do lst-f (:q)',
            \\    \ '    F1 ou ?        Abre este popup de ajuda',
            \\    \ '',
            \\    \ '  Pressione q, <Esc> ou <Enter> para fechar este popup',
            \\    \ ''
            \\  \ ]
            \\
            \\  if has('nvim')
            \\    let l:buf = nvim_create_buf(v:false, v:true)
            \\    call nvim_buf_set_lines(l:buf, 0, -1, v:true, l:lines)
            \\    let l:max_w = 72
            \\    for l:line in l:lines
            \\      let l:max_w = max([l:max_w, strdisplaywidth(l:line) + 4])
            \\    endfor
            \\    let l:width = min([l:max_w, &columns - 4])
            \\    let l:height = len(l:lines)
            \\    let l:row = max([1, (&lines - l:height) / 2 - 1])
            \\    let l:col = max([1, (&columns - l:width) / 2])
            \\    let l:opts = {
            \\      \ 'relative': 'editor',
            \\      \ 'row': l:row,
            \\      \ 'col': l:col,
            \\      \ 'width': l:width,
            \\      \ 'height': l:height,
            \\      \ 'style': 'minimal',
            \\      \ 'border': 'rounded',
            \\      \ 'title': l:title,
            \\      \ 'title_pos': 'center'
            \\    \ }
            \\    let l:win = nvim_open_win(l:buf, v:true, l:opts)
            \\    let l:close_cmd = ':lua pcall(vim.api.nvim_win_close, ' . l:win . ', true)<CR>'
            \\    for l:k in ['q', '<Esc>', '<CR>', '<Space>', '<F1>', '?']
            \\      execute 'nnoremap <buffer> <silent> ' . l:k . ' ' . l:close_cmd
            \\    endfor
            \\  elseif exists('*popup_create')
            \\    let l:win = popup_create(l:lines, {
            \\      \ 'title': l:title,
            \\      \ 'border': [],
            \\      \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
            \\      \ 'padding': [0, 1, 0, 1],
            \\      \ 'pos': 'center',
            \\      \ 'filter': function('s:lstf_popup_filter'),
            \\      \ 'close': 'none'
            \\    \ })
            \\  endif
            \\endfunction
            \\
            \\function! s:lstf_popup_filter(winid, key) abort
            \\  if a:key ==# 'q' || a:key ==# "\<Esc>" || a:key ==# "\<CR>" || a:key ==# ' ' || a:key ==# "\<F1>" || a:key ==# '?'
            \\    call popup_close(a:winid)
            \\    return 1
            \\  endif
            \\  call popup_close(a:winid)
            \\  return 0
            \\endfunction
            \\
            \\setlocal nonumber norelativenumber nowrap
            \\nnoremap <buffer> <silent> <F1> :call LstfHelp()<CR>
            \\nnoremap <buffer> <silent> ? :call LstfHelp()<CR>
            \\nnoremap <buffer> <silent> q :q<CR>
            \\
        );
        try w.flush();
    }
};
