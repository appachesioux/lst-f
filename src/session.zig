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
            \\    \ '  • Edite o caminho e use :w: renomeia ou move (cria os pais que faltarem)',
            \\    \ '  • :w sem edicao apenas atualiza a lista e mantem a sessao aberta',
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
            \\    \ '    Enter          Abre arquivo ou entra no diretorio da linha',
            \\    \ '    -              Volta ao diretorio-pai',
            \\    \ '    \\              Mostra a arvore visual do diretorio',
            \\    \ '    q, :q, :quit, ZZ  Saem do lst-f (tambem depois de renomear)',
            \\    \ '    F1 ou ?        Abre este popup de ajuda',
            \\    \ '',
            \\    \ '  Em terminal estreito, zl/zh rolam horizontalmente',
            \\     '',
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
            \\    let l:height = min([len(l:lines), &lines - 4])
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
            \\function! s:lstf_tree_filter(winid, key) abort
            \\  if a:key ==# 'q' || a:key ==# "\<Esc>" || a:key ==# "\<CR>" || (len(a:key) == 1 && char2nr(a:key) == 92)
            \\    call popup_close(a:winid)
            \\    return 1
            \\  endif
            \\  return popup_filter_menu(a:winid, a:key)
            \\endfunction
            \\
            \\function! s:lstf_entry_path() abort
            \\  let l:line = getline('.')
            \\  if l:line !~# '^\d\+\s\+'
            \\    return ''
            \\  endif
            \\  let l:body = substitute(l:line, '^\d\+\s\+', '', '')
            \\  let l:sep = strridx(l:body, ' │ ')
            \\  if l:sep >= 0
            \\    let l:res = strpart(l:body, l:sep + 5)
            \\    return substitute(l:res, '^\s*', '', '')
            \\  endif
            \\  let l:sep2 = stridx(l:body, '  │  ')
            \\  if l:sep2 >= 0
            \\    return strpart(l:body, l:sep2 + 7)
            \\  endif
            \\  return l:body
            \\endfunction
            \\
            \\function! LstfOpen() abort
            \\  let l:path = s:lstf_entry_path()
            \\  if empty(l:path)
            \\    return
            \\  endif
            \\  if isdirectory(l:path)
            \\    call s:lstf_navigate(l:path)
            \\  else
            \\    execute 'edit ' . fnameescape(l:path)
            \\  endif
            \\endfunction
            \\
            \\function! s:lstf_navigate(path) abort
            \\  call append('$', ':cd ' . a:path)
            \\  write
            \\endfunction
            \\
            \\function! LstfUp() abort
            \\  call s:lstf_navigate('..')
            \\endfunction
            \\
            \\function! LstfQuit() abort
            \\  call append('$', ':quit')
            \\  write
            \\endfunction
            \\
            \\function! s:lstf_prepare_save() abort
            \\  if search('^:', 'nw') == 0
            \\    call append('$', ':refresh')
            \\  endif
            \\  let l:start = s:lstf_content_start()
            \\  let l:relative_line = l:start > 0 ? max([0, line('.') - l:start]) : 0
            \\  call writefile([string(l:relative_line)], $LST_F_STATE . '/cursor')
            \\endfunction
            \\
            \\function! s:lstf_content_start() abort
            \\  return search('^\d\+\s\+', 'nW')
            \\endfunction
            \\
            \\function! LstfTree() abort
            \\  let l:lines = readfile($LST_F_STATE . '/tree')
            \\  if empty(l:lines)
            \\    let l:lines = ['(arvore vazia)']
            \\  endif
            \\  if has('nvim')
            \\    let l:buf = nvim_create_buf(v:false, v:true)
            \\    call nvim_buf_set_lines(l:buf, 0, -1, v:true, l:lines)
            \\    let l:width = min([max([50, max(map(copy(l:lines), 'strdisplaywidth(v:val) + 4'))]), &columns - 4])
            \\    let l:height = min([len(l:lines), &lines - 4])
            \\    let l:opts = {'relative': 'editor', 'row': max([1, (&lines - l:height) / 2 - 1]), 'col': max([1, (&columns - l:width) / 2]), 'width': l:width, 'height': l:height, 'style': 'minimal', 'border': 'rounded', 'title': ' Tree ', 'title_pos': 'center'}
            \\    let l:win = nvim_open_win(l:buf, v:true, l:opts)
            \\    let l:close = ':lua pcall(vim.api.nvim_win_close, ' . l:win . ', true)<CR>'
            \\    for l:k in ['q', '<Esc>', '<CR>', '<Bslash>']
            \\      execute 'nnoremap <buffer> <silent> ' . l:k . ' ' . l:close
            \\    endfor
            \\  elseif exists('*popup_create')
            \\    let l:win = popup_create(l:lines, {'title': ' Tree ', 'border': [], 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'], 'padding': [0, 1, 0, 1], 'pos': 'center', 'cursorline': v:true, 'filter': function('s:lstf_tree_filter'), 'close': 'none'})
            \\  else
            \\    echo join(l:lines, "\n")
            \\  endif
            \\endfunction
            \\
            \\setglobal laststatus=0
            \\set laststatus=0
            \\if exists('+fillchars')
            \\  execute "setlocal fillchars+=eob:\\ "
            \\endif
            \\set noruler noshowcmd
            \\setlocal nonumber norelativenumber nowrap sidescrolloff=8
            \\syntax match LstfInternalId /^\d\+\s\+/ conceal
            \\setlocal conceallevel=2 concealcursor=nv
            \\augroup lstf_buffer
            \\  autocmd! * <buffer>
            \\  autocmd BufWritePre <buffer> call s:lstf_prepare_save()
            \\  autocmd BufWritePost <buffer> quit
            \\  autocmd VimEnter,BufWinEnter,WinEnter <buffer> setglobal laststatus=0
            \\augroup END
            \\if filereadable($LST_F_STATE . '/cursor')
            \\  let s:lstf_start = s:lstf_content_start()
            \\  let s:lstf_offset = get(readfile($LST_F_STATE . '/cursor'), 0, '0')
            \\  if s:lstf_start > 0
            \\    execute 'call cursor(' . (s:lstf_start + s:lstf_offset) . ', 1)'
            \\  endif
            \\else
            \\  let s:lstf_start = s:lstf_content_start()
            \\  if s:lstf_start > 0
            \\    call cursor(s:lstf_start, 1)
            \\  endif
            \\endif
            \\nnoremap <buffer> <silent> <F1> :call LstfHelp()<CR>
            \\nnoremap <buffer> <silent> ? :call LstfHelp()<CR>
            \\nnoremap <buffer> <silent> <CR> :call LstfOpen()<CR>
            \\nnoremap <buffer> <silent> - :call LstfUp()<CR>
            \\nnoremap <buffer> <silent> <Bslash> :call LstfTree()<CR>
            \\nnoremap <buffer> <silent> q :call LstfQuit()<CR>
            \\nnoremap <buffer> <silent> ZZ :call LstfQuit()<CR>
            \\cnoreabbrev <expr> <buffer> q getcmdtype() ==# ':' && getcmdline() ==# 'q' ? 'call LstfQuit()' : 'q'
            \\cnoreabbrev <expr> <buffer> quit getcmdtype() ==# ':' && getcmdline() ==# 'quit' ? 'call LstfQuit()' : 'quit'
            \\
        );
        try w.flush();
    }
};
