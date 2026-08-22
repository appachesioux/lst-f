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
pub const env_location = "LST_F_LOCATION";

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
            \\let s:lstf_identity = '
        );
        try w.print("{s} v{s}", .{ app_name, version });
        try w.writeAll(
            \\'
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
            \\    \ '    :hidden        Alterna exibicao de arquivos ocultos',
            \\    \ '    :undo          Desfaz a ultima operacao aplicada na sessao',
            \\    \ '    :quit          Sai da sessao (:cq aborta sem aplicar nada)',
            \\    \ '',
            \\    \ '  Atalhos no buffer:',
            \\    \ '    .              Alterna exibicao de arquivos ocultos',
            \\    \ '    Ctrl+P         Abre a busca fuzzy (fzf) na arvore inteira',
            \\    \ '    Enter          Abre arquivo ou entra no diretorio da linha',
            \\    \ '    - ou <         Volta ao diretorio-pai',
            \\    \ '    >              Entra no diretorio da linha',
            \\    \ '    \              Mostra a arvore visual do diretorio',
            \\    \ '    Ctrl+S         Abre / fecha painel de destino (split)',
            \\    \ '    Tab            Alterna foco entre painel principal e destino',
            \\    \ '    Y ou yy (dest) Copia caminho do destino para colar (p)',
            \\    \ '    q, :q, :quit, ZZ  Saem do lst-f (tambem depois de renomear)',
            \\    \ '    F1 ou ?        Abre este popup de ajuda',
            \\    \ '',
            \\    \ '  Em terminal estreito, zl/zh rolam horizontalmente',
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
            \\  return popup_filter_menu(a:winid, a:key)
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
            \\function! s:lstf_is_binary(path) abort
            \\  let l:ext = tolower(fnamemodify(a:path, ':e'))
            \\  if empty(l:ext)
            \\    return 0
            \\  endif
            \\  let l:bin_exts = [
            \\    \ 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'epub',
            \\    \ 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'ico', 'webp', 'svg', 'tif', 'tiff', 'psd', 'raw', 'heic', 'avif',
            \\    \ 'mp3', 'mp4', 'avi', 'mkv', 'mov', 'flac', 'wav', 'ogg', 'webm', 'm4a', 'aac', 'wma', 'wmv',
            \\    \ 'zip', 'tar', 'gz', 'bz2', 'xz', '7z', 'rar', 'zst', 'lz4',
            \\    \ 'exe', 'dll', 'so', 'dylib', 'o', 'a', 'lib', 'bin', 'dat',
            \\    \ 'ttf', 'otf', 'woff', 'woff2',
            \\    \ 'class', 'pyc', 'wasm', 'sqlite', 'db'
            \\    \ ]
            \\  return index(l:bin_exts, l:ext) >= 0
            \\endfunction
            \\
            \\function! s:lstf_open_external(path) abort
            \\  if executable('xdg-open')
            \\    if has('nvim')
            \\      call jobstart(['xdg-open', a:path], {'detach': v:true})
            \\    elseif exists('*job_start')
            \\      call job_start(['xdg-open', a:path], {'stoponexit': ''})
            \\    else
            \\      call system('xdg-open ' . shellescape(a:path) . ' >/dev/null 2>&1 &')
            \\    endif
            \\    redraw
            \\    echo 'Aberto via xdg-open: ' . a:path
            \\    return 1
            \\  endif
            \\  return 0
            \\endfunction
            \\
            \\function! LstfOpen() abort
            \\  let l:path = s:lstf_entry_path()
            \\  if empty(l:path)
            \\    return
            \\  endif
            \\  if isdirectory(l:path)
            \\    call s:lstf_navigate(l:path)
            \\  elseif s:lstf_is_binary(l:path) && s:lstf_open_external(l:path)
            \\    return
            \\  else
            \\    call s:lstf_write_directive(':open ' . l:path)
            \\  endif
            \\endfunction
            \\
            \\function! s:lstf_navigate(path) abort
            \\  call s:lstf_write_directive(':cd ' . a:path)
            \\endfunction
            \\
            \\function! s:lstf_write_directive(directive) abort
            \\  " Atalhos podem ser repetidos antes que o Vim feche. Uma unica
            \\  " diretiva e valida; remover as anteriores evita travar o parser.
            \\  for l:lnum in reverse(range(1, line('$')))
            \\    if getline(l:lnum) =~# '^:'
            \\      execute l:lnum . 'delete _'
            \\    endif
            \\  endfor
            \\  call append('$', a:directive)
            \\  write
            \\endfunction
            \\
            \\function! LstfUp() abort
            \\  call s:lstf_navigate('..')
            \\endfunction
            \\
            \\function! LstfEnterDir() abort
            \\  let l:path = s:lstf_entry_path()
            \\  if !empty(l:path) && isdirectory(l:path)
            \\    call s:lstf_navigate(l:path)
            \\  endif
            \\endfunction
            \\
            \\function! LstfQuit() abort
            \\  call s:lstf_write_directive(':quit')
            \\endfunction
            \\
            \\function! LstfFind() abort
            \\  call s:lstf_write_directive(':find')
            \\endfunction
            \\
            \\function! LstfToggleHidden() abort
            \\  call s:lstf_write_directive(':hidden')
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
            \\function! s:lstf_stretch_header() abort
            \\  let l:title = 'T │ PERMS     │ SIZE      │ MODIFIED         │ NAME'
            \\  let l:top = '──┬───────────┬───────────┬──────────────────┬'
            \\  let l:bottom = '──┼───────────┼───────────┼──────────────────┼'
            \\  for l:lnum in range(2, line('$') - 1)
            \\    if getline(l:lnum) !=# l:title | continue | endif
            \\    call setline(l:lnum - 1, l:top . repeat('─', max([0, &columns - strdisplaywidth(l:top)])))
            \\    call setline(l:lnum, l:title . repeat(' ', max([0, &columns - strdisplaywidth(l:title)])))
            \\    call setline(l:lnum + 1, l:bottom . repeat('─', max([0, &columns - strdisplaywidth(l:bottom)])))
            \\    break
            \\  endfor
            \\  setlocal nomodified
            \\endfunction
            \\
            \\function! LstfStatusline() abort
            \\  let l:start = s:lstf_content_start()
            \\  let l:total = l:start > 0 ? len(filter(getline(l:start, '$'), 'v:val =~# ''^\d\+\s\+''')) : 0
            \\  let l:current = l:start > 0 && line('.') >= l:start ? len(filter(getline(l:start, line('.')), 'v:val =~# ''^\d\+\s\+''')) : 0
            \\  let l:mode = mode(1) =~# '^[iR]' ? 'EDIT' : mode(1) =~# '^[vV]' ? 'VISUAL' : 'NORMAL'
            \\  let l:name = substitute(s:lstf_entry_path(), '%', '%%', 'g')
            \\  let l:location = empty($LST_F_LOCATION) ? fnamemodify(getcwd(), ':~') : $LST_F_LOCATION
            \\  let l:location = substitute(l:location, '%', '%%', 'g')
            \\  let l:editor = has('nvim') ? 'Neovim' : 'Vim'
            \\  return '%#LstfStatusMode# ' . l:mode . ' %#LstfStatusInfo# ' . l:current . '/' . l:total . (empty(l:name) ? '' : '  ' . l:name) . '%=%#LstfStatusInfo# ' . s:lstf_identity . '  ' . l:location . '  ·  ' . l:editor . ' %#LstfStatusHelp# F1=Help '
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
            \\function! s:lstf_format_size(bytes) abort
            \\  if a:bytes < 0
            \\    return '-'
            \\  elseif a:bytes < 1024
            \\    return string(a:bytes) . 'B'
            \\  elseif a:bytes < 1048576
            \\    return printf('%.1fK', a:bytes / 1024.0)
            \\  elseif a:bytes < 1073741824
            \\    return printf('%.1fM', a:bytes / 1048576.0)
            \\  else
            \\    return printf('%.1fG', a:bytes / 1073741824.0)
            \\  endif
            \\endfunction
            \\
            \\let s:lstf_dest_dir = ''
            \\
            \\function! s:lstf_render_dest(dir) abort
            \\  let s:lstf_dest_dir = simplify(fnamemodify(a:dir, ':p'))
            \\  if s:lstf_dest_dir !~# '/$'
            \\    let s:lstf_dest_dir .= '/'
            \\  endif
            \\  let l:raw_entries = globpath(s:lstf_dest_dir, '*', 0, 1)
            \\  if get(s:, 'lstf_dest_hidden', 0)
            \\    let l:raw_entries += globpath(s:lstf_dest_dir, '.*', 0, 1)
            \\  endif
            \\  let l:dirs = []
            \\  let l:files = []
            \\  for l:item in l:raw_entries
            \\    let l:tail = fnamemodify(l:item, ':t')
            \\    if l:tail ==# '.' || l:tail ==# '..' || l:tail =~# '^\.lst-f-'
            \\      continue
            \\    endif
            \\    if isdirectory(l:item)
            \\      call add(l:dirs, l:tail . '/')
            \\    else
            \\      call add(l:files, l:tail)
            \\    endif
            \\  endfor
            \\  call sort(l:dirs)
            \\  call sort(l:files)
            \\  let l:lines = [
            \\    \ 'DESTINATION: ' . s:lstf_dest_dir,
            \\    \ '──┬───────────┬───────────┬──────────────────┬──────────────────────────',
            \\    \ 'T │ PERMS     │ SIZE      │ MODIFIED         │ NAME [Y=copy . =hidden]',
            \\    \ '──┼───────────┼───────────┼──────────────────┼──────────────────────────',
            \\    \ 'd │ rwxr-xr-x │         - │                - │  ../'
            \\    \ ]
            \\  for l:d in l:dirs
            \\    let l:full = s:lstf_dest_dir . l:d
            \\    let l:mtime = strftime('%Y-%m-%d %H:%M', getftime(l:full))
            \\    let l:perm = getfperm(l:full)
            \\    if empty(l:perm) | let l:perm = 'rwxr-xr-x' | endif
            \\    call add(l:lines, printf('d │ %-9s │ %9s │ %-16s │  %s', l:perm, '-', l:mtime, l:d))
            \\  endfor
            \\  for l:f in l:files
            \\    let l:full = s:lstf_dest_dir . l:f
            \\    let l:sz = getfsize(l:full)
            \\    let l:sz_str = s:lstf_format_size(l:sz)
            \\    let l:mtime = strftime('%Y-%m-%d %H:%M', getftime(l:full))
            \\    let l:perm = getfperm(l:full)
            \\    if empty(l:perm) | let l:perm = 'rw-r--r--' | endif
            \\    call add(l:lines, printf('- │ %-9s │ %9s │ %-16s │  %s', l:perm, l:sz_str, l:mtime, l:f))
            \\  endfor
            \\  setlocal modifiable
            \\  silent %delete _
            \\  call setline(1, l:lines)
            \\  setlocal nomodified nomodifiable
            \\  execute 'call cursor(5, 1)'
            \\endfunction
            \\
            \\function! s:lstf_dest_toggle_hidden() abort
            \\  let s:lstf_dest_hidden = !get(s:, 'lstf_dest_hidden', 0)
            \\  call s:lstf_render_dest(s:lstf_dest_dir)
            \\endfunction
            \\
            \\function! s:lstf_dest_open() abort
            \\  let l:line = getline('.')
            \\  let l:sep = strridx(l:line, ' │  ')
            \\  if l:sep < 0
            \\    let l:sep = strridx(l:line, ' │ ')
            \\    if l:sep < 0 | return | endif
            \\    let l:name = substitute(strpart(l:line, l:sep + 3), '^\s*', '', '')
            \\  else
            \\    let l:name = strpart(l:line, l:sep + 4)
            \\  endif
            \\  if l:name ==# '../' || l:name ==# '..'
            \\    let l:parent = fnamemodify(s:lstf_dest_dir, ':h:h')
            \\    if empty(l:parent) | let l:parent = '/' | endif
            \\    call s:lstf_render_dest(l:parent)
            \\    return
            \\  endif
            \\  let l:target = s:lstf_dest_dir . l:name
            \\  if isdirectory(l:target)
            \\    call s:lstf_render_dest(l:target)
            \\  else
            \\    let @\" = l:target
            \\    let @+ = l:target
            \\    let @* = l:target
            \\    echo 'Destino copiado: ' . l:target
            \\  endif
            \\endfunction
            \\
            \\function! s:lstf_dest_up() abort
            \\  let l:parent = fnamemodify(s:lstf_dest_dir, ':h:h')
            \\  if empty(l:parent) | let l:parent = '/' | endif
            \\  call s:lstf_render_dest(l:parent)
            \\endfunction
            \\
            \\function! s:lstf_dest_yank() abort
            \\  let l:line = getline('.')
            \\  let l:sep = strridx(l:line, ' │  ')
            \\  if l:sep < 0
            \\    let l:sep = strridx(l:line, ' │ ')
            \\  endif
            \\  if l:sep >= 0
            \\    let l:name = substitute(strpart(l:line, l:sep + 3), '^\s*', '', '')
            \\  else
            \\    let l:name = ''
            \\  endif
            \\  if !empty(l:name) && l:name !=# '../' && l:name !=# '..'
            \\    let l:path = s:lstf_dest_dir . l:name
            \\  else
            \\    let l:path = s:lstf_dest_dir
            \\  endif
            \\  let @\" = l:path
            \\  let @+ = l:path
            \\  let @* = l:path
            \\  echo 'Caminho copiado: ' . l:path
            \\endfunction
            \\
            \\function! LstfToggleSplit() abort
            \\  if exists('t:lstf_dest_win') && win_id2win(t:lstf_dest_win) > 0
            \\    let l:w = win_id2win(t:lstf_dest_win)
            \\    execute l:w . 'close'
            \\    unlet! t:lstf_dest_win
            \\    return
            \\  endif
            \\  if winnr('$') > 1
            \\    wincmd w
            \\    if &buftype ==# 'nofile'
            \\      close
            \\      return
            \\    else
            \\      wincmd p
            \\    endif
            \\  endif
            \\  botright vsplit __lstf_dest_panel__
            \\  let t:lstf_dest_win = win_getid()
            \\  setlocal buftype=nofile bufhidden=wipe noswapfile nowrap
            \\  setlocal nonumber norelativenumber cursorline
            \\  nnoremap <buffer> <silent> <CR> :call <SID>lstf_dest_open()<CR>
            \\  nnoremap <buffer> <silent> - :call <SID>lstf_dest_up()<CR>
            \\  nnoremap <buffer> <silent> . :call <SID>lstf_dest_toggle_hidden()<CR>
            \\  nnoremap <buffer> <silent> Y :call <SID>lstf_dest_yank()<CR>
            \\  nnoremap <buffer> <silent> yy :call <SID>lstf_dest_yank()<CR>
            \\  nnoremap <buffer> <silent> <C-s> :call LstfToggleSplit()<CR>
            \\  nnoremap <buffer> <silent> <C-p> :call LstfFind()<CR>
            \\  " `q` deve encerrar o lst-f independentemente do painel em foco.
            \\  " Esc e Ctrl+S continuam sendo as formas de fechar so este painel.
            \\  nnoremap <buffer> <silent> q :wincmd p<Bar>call LstfQuit()<CR>
            \\  nnoremap <buffer> <silent> <Esc> :close<CR>
            \\  nnoremap <buffer> <silent> <Tab> :wincmd w<CR>
            \\  nnoremap <buffer> <silent> <F1> :call LstfHelp()<CR>
            \\  nnoremap <buffer> <silent> ? :call LstfHelp()<CR>
            \\  call s:lstf_render_dest(getcwd())
            \\endfunction
            \\
            \\function! s:lstf_tab_jump() abort
            \\  if winnr('$') > 1
            \\    wincmd w
            \\  else
            \\    call LstfToggleSplit()
            \\  endif
            \\endfunction
            \\
            \\highlight LstfStatusMode cterm=bold ctermfg=0 ctermbg=12 gui=bold guifg=#1e1e2e guibg=#89b4fa
            \\highlight LstfStatusInfo ctermfg=7 ctermbg=NONE guifg=#cdd6f4 guibg=NONE
            \\highlight LstfStatusHelp cterm=bold ctermfg=0 ctermbg=12 gui=bold guifg=#1e1e2e guibg=#89b4fa
            \\highlight CursorLine cterm=NONE ctermbg=240 gui=NONE guibg=#45475a
            \\set laststatus=2
            \\setlocal statusline=%!LstfStatusline()
            \\set noshowmode showtabline=0
            \\set shortmess+=F
            \\if exists('+fillchars')
            \\  execute "setlocal fillchars+=eob:\\ "
            \\endif
            \\set noruler noshowcmd
            \\setlocal nonumber norelativenumber nowrap sidescrolloff=8 cursorline cursorlineopt=line
            \\syntax match LstfInternalId /^\d\+\s\+/ conceal
            \\" O sequencial e metadado interno: oculta-lo tambem na linha do
            \\" cursor evita deslocar as colunas, inclusive ao voltar do :find.
            \\setlocal conceallevel=2 concealcursor=nvic
            \\augroup lstf_buffer
            \\  autocmd! * <buffer>
            \\  autocmd BufWritePre <buffer> call s:lstf_prepare_save()
            \\  " O painel de destino pode estar aberto: `quit` fecharia so a
            \\  " janela da lista e deixaria o processo Vim preso no painel.
            \\  autocmd BufWritePost <buffer> quitall
            \\augroup END
            \\augroup lstf_statusline
            \\  autocmd!
            \\  autocmd ModeChanged * redrawstatus
            \\augroup END
            \\call s:lstf_stretch_header()
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
            \\" A ajuda pode manter o foco em um popup ou painel auxiliar. Como esta
            \\" instancia do Vim e exclusiva do lst-f, F1 e global para nunca deixar
            \\" o Vim abrir :help em um split e alterar a tela controlada.
            \\nnoremap <silent> <F1> :call LstfHelp()<CR>
            \\nnoremap <buffer> <silent> ? :call LstfHelp()<CR>
            \\nnoremap <buffer> <silent> <CR> :call LstfOpen()<CR>
            \\nnoremap <buffer> <silent> . :call LstfToggleHidden()<CR>
            \\nnoremap <buffer> <silent> - :call LstfUp()<CR>
            \\nnoremap <buffer> <silent> <lt> :call LstfUp()<CR>
            \\nnoremap <buffer> <silent> > :call LstfEnterDir()<CR>
            \\nnoremap <buffer> <silent> <Bslash> :call LstfTree()<CR>
            \\nnoremap <buffer> <silent> <C-p> :call LstfFind()<CR>
            \\nnoremap <buffer> <silent> <C-s> :call LstfToggleSplit()<CR>
            \\nnoremap <buffer> <silent> <Tab> :call <SID>lstf_tab_jump()<CR>
            \\nnoremap <buffer> <silent> q :call LstfQuit()<CR>
            \\nnoremap <buffer> <silent> ZZ :call LstfQuit()<CR>
            \\cnoreabbrev <expr> <buffer> q getcmdtype() ==# ':' && getcmdline() ==# 'q' ? 'call LstfQuit()' : 'q'
            \\cnoreabbrev <expr> <buffer> quit getcmdtype() ==# ':' && getcmdline() ==# 'quit' ? 'call LstfQuit()' : 'quit'
            \\redrawstatus | echo ''
            \\
        );
        try w.flush();
    }
};
