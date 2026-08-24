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

const testing = std.testing;

test "historico anda para tras e para frente" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h: History = .{};
    try h.push(arena, "/a");
    try h.push(arena, "/b");
    try h.push(arena, "/c");

    try testing.expectEqualStrings("/b", h.back().?);
    try testing.expectEqualStrings("/a", h.back().?);
    try testing.expectEqual(@as(?[]const u8, null), h.back());
    try testing.expectEqualStrings("/b", h.forward().?);
    try testing.expectEqualStrings("/c", h.forward().?);
    try testing.expectEqual(@as(?[]const u8, null), h.forward());
}

test "entrar em diretorio novo descarta o caminho a frente" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h: History = .{};
    try h.push(arena, "/a");
    try h.push(arena, "/b");
    try h.push(arena, "/c");
    _ = h.back();
    _ = h.back();
    try h.push(arena, "/d");

    try testing.expectEqual(@as(usize, 2), h.items.items.len);
    try testing.expectEqual(@as(?[]const u8, null), h.forward());
    try testing.expectEqualStrings("/a", h.back().?);
}

test "ficar no mesmo diretorio nao empilha" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h: History = .{};
    try h.push(arena, "/a");
    try h.push(arena, "/a");
    try h.push(arena, "/b");
    _ = h.back();
    // Um `:refresh` no meio do historico nao pode virar uma ida nova.
    try h.push(arena, "/a");
    try testing.expectEqual(@as(usize, 2), h.items.items.len);
    try testing.expectEqualStrings("/b", h.forward().?);
}

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
        var file = try s.dir.createFile(io, "helper.vim", .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer: Io.File.Writer = .init(file, io, &buffer);
        const w = &writer.interface;

        try w.writeAll(
            \\set nocompatible
            \\let s:lstf_notice = filereadable($LST_F_STATE . '/notice')
            \\  \ ? get(readfile($LST_F_STATE . '/notice'), 0, '') : ''
            \\let s:lstf_titles = filereadable($LST_F_STATE . '/titles')
            \\  \ ? get(readfile($LST_F_STATE . '/titles'), 0, '') : ''
            \\let s:lstf_identity = '
        );
        try w.print("{s} v{s}", .{ app_name, version });
        try w.writeAll(
            \\'
            \\" Sem titulos nao ha grade para descrever, e a janela de cabecalho
            \\" nao chega a existir.
            \\let s:lstf_frame = !empty(s:lstf_titles)
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
            \\    \ '  • Nome em linha nova: cria arquivo ( / no fim cria diretorio)',
            \\    \ '  • So o nome e editavel: cabecalho e colunas voltam sozinhos',
            \\    \ '  • /0000 oculto    : vincula a linha (:sort e reordenar sao seguros)',
            \\    \ '',
            \\    \ '  Diretivas (escreva no buffer e salve):',
            \\    \ '    :cd <dir>      Entra no diretorio (.. sobe)',
            \\    \ '    :find [termo]  Busca recursiva fuzzy na arvore com fzf',
            \\    \ '    :hidden        Alterna exibicao de arquivos ocultos',
            \\    \ '    :back/:forward Andam pelos diretorios visitados na sessao',
            \\    \ '    :undo          Desfaz a ultima operacao aplicada na sessao',
            \\    \ '    :quit          Sai da sessao (:cq aborta sem aplicar nada)',
            \\    \ '',
            \\    \ '  Atalhos no buffer:',
            \\    \ '    .              Alterna exibicao de arquivos ocultos',
            \\    \ '    Ctrl+P         Abre a busca fuzzy (fzf) na arvore inteira',
            \\    \ '    Enter          Abre arquivo ou entra no diretorio da linha',
            \\    \ '    -              Sobe para o diretorio-pai',
            \\    \ '    < e >          Voltam e avancam nos diretorios visitados',
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
            \\function! s:lstf_entry_path(...) abort
            \\  let l:line = a:0 > 0 ? a:1 : getline('.')
            \\  if l:line !~# '^/\d\+\s\+'
            \\    return ''
            \\  endif
            \\  let l:body = substitute(l:line, '^/\d\+\s\+', '', '')
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
            \\    let $LST_F_LIVE_ARG = l:path
            \\    call s:lstf_nav('enter', ':cd ' . l:path)
            \\    unlet $LST_F_LIVE_ARG
            \\  elseif s:lstf_is_binary(l:path) && s:lstf_open_external(l:path)
            \\    return
            \\  else
            \\    call s:lstf_write_directive(':open ' . l:path)
            \\  endif
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
            \\" Navegacao viva: o pai relista, regrava o buffer e responde; aqui
            \\" basta recarregar o mesmo arquivo, sem fechar o editor nem limpar a
            \\" tela. Com edicao pendente, o caminho e a diretiva antiga -- ela
            \\" passa pela confirmacao antes de qualquer coisa. O argumento do
            \\" `enter` vai por $LST_F_LIVE_ARG, nunca por argv.
            \\function! s:lstf_nav(cmd, directive) abort
            \\  if &modified
            \\    call s:lstf_write_directive(a:directive)
            \\    return
            \\  endif
            \\  let l:out = system($LST_F_SELF . ' --client ' . a:cmd)
            \\  if v:shell_error
            \\    echohl ErrorMsg
            \\    echomsg substitute(l:out, "\n\\+$", '', '')
            \\    echohl None
            \\    return
            \\  endif
            \\  silent! edit!
            \\  call s:lstf_after_reload()
            \\endfunction
            \\
            \\function! LstfUp() abort
            \\  call s:lstf_nav('up', ':cd ..')
            \\endfunction
            \\
            \\function! LstfBack() abort
            \\  call s:lstf_nav('back', ':back')
            \\endfunction
            \\
            \\function! LstfForward() abort
            \\  call s:lstf_nav('forward', ':forward')
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
            \\  call s:lstf_nav('hidden', ':hidden')
            \\endfunction
            \\
            \\function! s:lstf_prepare_save() abort
            \\  call delete($LST_F_STATE . '/approved')
            \\  let l:entries = s:lstf_entry_lines()
            \\  if exists('b:lstf_entry_lines') && l:entries !=# b:lstf_entry_lines
            \\    let l:answer = input('Apply filesystem changes? [y/N] ')
            \\    if tolower(l:answer) !=# 'y' && tolower(l:answer) !=# 'yes'
            \\      throw 'lst-f: operation cancelled'
            \\    endif
            \\    call writefile(['approved'], $LST_F_STATE . '/approved')
            \\  endif
            \\  if search('^:', 'nw') == 0
            \\    call append('$', ':refresh')
            \\  endif
            \\  let l:start = s:lstf_content_start()
            \\  let l:relative_line = l:start > 0 ? max([0, line('.') - l:start]) : 0
            \\  call writefile([string(l:relative_line)], $LST_F_STATE . '/cursor')
            \\endfunction
            \\
            \\function! s:lstf_entry_lines() abort
            \\  let l:start = s:lstf_content_start()
            \\  if l:start <= 0 | let l:start = len(get(b:, 'lstf_header', [])) + 1 | endif
            \\  return filter(getline(l:start, '$'), 'v:val !~# "^:" && v:val !~# "^#"')
            \\endfunction
            \\
            \\function! s:lstf_content_start() abort
            \\  " Do topo do buffer, nao do cursor: com 'nW' a "primeira entrada"
            \\  " era sempre a seguinte a ele, e o contador nascia zerado.
            \\  return match(getline(1, '$'), '^/\d\+\s\+') + 1
            \\endfunction
            \\
            \\" O cabecalho e a barra de titulo desta tela, nao conteudo: se uma
            \\" tecla o apagar ou um :sort o deslocar, ele volta para o topo.
            \\function! s:lstf_restore_header() abort
            \\  let l:want = get(b:, 'lstf_header', [])
            \\  if empty(l:want) | return | endif
            \\  if getline(1, len(l:want)) ==# l:want | return | endif
            \\  let l:view = winsaveview()
            \\  let l:body = filter(getline(1, '$'),
            \\    \ 'index(l:want, v:val) < 0 && v:val !~# "^──" && v:val !~# "^T │ PERMS"')
            \\  silent! undojoin
            \\  call setline(1, l:want + l:body)
            \\  let l:total = len(l:want) + len(l:body)
            \\  if line('$') > l:total
            \\    silent! execute (l:total + 1) . ',$delete _'
            \\  endif
            \\  call winrestview(l:view)
            \\  call s:lstf_keep_cursor_below_header()
            \\endfunction
            \\
            \\" Nem Vim nem Neovim trancam um intervalo de linhas: 'modifiable' e
            \\" do buffer inteiro. O par abaixo faz o papel -- o cursor nao entra
            \\" no cabecalho e o que passar por cima dele volta na hora.
            \\function! s:lstf_keep_cursor_below_header() abort
            \\  let l:end = len(get(b:, 'lstf_header', []))
            \\  if l:end <= 0 || line('.') > l:end | return | endif
            \\  if line('$') <= l:end | return | endif
            \\  if mode() =~# "^[vV\x16]" | return | endif
            \\  call cursor(l:end + 1, col('.'))
            \\endfunction
            \\
            \\" Comeco do nome na linha: depois do ID e da grade de colunas.
            \\function! s:lstf_name_start(line) abort
            \\  return matchend(a:line, '^/\d\+\s\+\%(.*│  \)\?')
            \\endfunction
            \\
            \\" So o nome e editavel. As colunas tecnicas ja eram ignoradas pelo
            \\" plano; aqui elas param de ser alcancaveis pelo cursor, e o que
            \\" escapar (:s, colagem) volta ao lugar assim que o texto muda.
            \\function! s:lstf_keep_cursor_in_name() abort
            \\  let l:line = getline('.')
            \\  " Linha nova (sem ID) e editavel inteira.
            \\  let l:id = matchstr(l:line, '^/\d\+')
            \\  if empty(l:id) || !has_key(get(b:, 'lstf_prefix', {}), l:id) | return | endif
            \\  let l:start = s:lstf_name_start(l:line)
            \\  if l:start <= 0 | return | endif
            \\  if col('.') <= l:start | call cursor(line('.'), l:start + 1) | endif
            \\endfunction
            \\
            \\function! s:lstf_restore_columns() abort
            \\  if !exists('b:lstf_prefix') | return | endif
            \\  let l:line = getline('.')
            \\  let l:id = matchstr(l:line, '^/\d\+')
            \\  if empty(l:id) || !has_key(b:lstf_prefix, l:id) | return | endif
            \\  let l:want = b:lstf_prefix[l:id]
            \\  if strpart(l:line, 0, len(l:want)) ==# l:want | return | endif
            \\  let l:name = matchstr(l:line, '.*│\s*\zs.*')
            \\  if empty(l:name) | let l:name = matchstr(l:line, '^/\d\+\s\+\zs.*') | endif
            \\  let l:view = winsaveview()
            \\  silent! undojoin
            \\  call setline(line('.'), l:want . l:name)
            \\  call winrestview(l:view)
            \\endfunction
            \\
            \\function! s:lstf_capture_prefixes() abort
            \\  let b:lstf_prefix = {}
            \\  let b:lstf_id_width = 0
            \\  for l:line in getline(1, '$')
            \\    let l:id = matchstr(l:line, '^/\d\+')
            \\    if empty(l:id) | continue | endif
            \\    if b:lstf_id_width == 0
            \\      let b:lstf_id_width = matchend(l:line, '^/\d\+\s\+')
            \\    endif
            \\    let l:start = s:lstf_name_start(l:line)
            \\    if l:start > 0 | let b:lstf_prefix[l:id] = strpart(l:line, 0, l:start) | endif
            \\  endfor
            \\endfunction
            \\
            \\" Barra de topo: os titulos das colunas sao linha de tela, nao de
            \\" buffer. Nao rolam com a lista, nao dao para apagar e se redesenham
            \\" sozinhos quando o terminal muda de tamanho.
            \\" A barra e da tela inteira, mas descreve a janela da lista: a posicao
            \\" fica guardada aqui, atualizada so de dentro dela, para que o foco no
            \\" painel de destino nao a faca seguir a janela errada.
            \\function! s:lstf_follow_scroll() abort
            \\  " A moldura e texto de buffer, entao nao se reajusta sozinha quando a
            \\  " largura muda. A janela de cabecalho tem sempre a largura da lista:
            \\  " o painel de destino e um vsplit de altura inteira, ao lado das duas.
            \\  if s:lstf_frame && winwidth(0) != get(s:, 'lstf_frame_width', -1)
            \\    call s:lstf_draw_frame()
            \\  endif
            \\  let l:left = winsaveview().leftcol
            \\  let s:lstf_id_width = get(b:, 'lstf_id_width', 0)
            \\  if l:left == get(s:, 'lstf_leftcol', -1) | return | endif
            \\  let s:lstf_leftcol = l:left
            \\  " Os titulos sao a statusline da janela de cabecalho, que so se
            \\  " redesenha sob pedido: `!` alcanca a janela que nao esta em foco.
            \\  if s:lstf_frame
            \\    call s:lstf_draw_frame()
            \\    redrawstatus!
            \\  endif
            \\endfunction
            \\
            \\" Os titulos com um fundo por coluna e o divisor sobre o fundo da tela,
            \\" como na grade do xpl-f. Sao a statusline da janela de cabecalho: e
            \\" o `%!` que permite um grupo de destaque por coluna.
            \\function! LstfTitlesBar() abort
            \\  if empty(s:lstf_titles) | return '' | endif
            \\  " Acompanha a rolagem horizontal da lista, senao as colunas sairiam
            \\  " do lugar assim que um nome longo empurrar a tela. O `leftcol`
            \\  " conta tambem os caracteres do ID, que estao no buffer mas
            \\  " ocultos por conceal e nao existem na barra.
            \\  let l:left = get(s:, 'lstf_leftcol', 0) - get(s:, 'lstf_id_width', 0)
            \\  let l:rest = strcharpart(s:lstf_titles, max([0, l:left]))
            \\  " A faixa vai ate a borda da janela por conta propria: o
            \\  " preenchimento de `%=` sairia no grupo StatusLineNC, que e da
            \\  " barra de baixo tambem.
            \\  let l:win = exists('g:statusline_winid') ? win_id2win(g:statusline_winid) : 0
            \\  let l:pad = max([0, winwidth(l:win) - strdisplaywidth(l:rest)])
            \\  let l:out = ''
            \\  while 1
            \\    let l:sep = matchstr(l:rest, ' \=│ \=')
            \\    if empty(l:sep) | break | endif
            \\    let l:i = match(l:rest, ' \=│ \=')
            \\    let l:out .= '%#LstfTitles#' . strpart(l:rest, 0, l:i) . '%#LstfTitlesSep#' . l:sep
            \\    let l:rest = strpart(l:rest, l:i + len(l:sep))
            \\  endwhile
            \\  return l:out . '%#LstfTitles#' . l:rest . repeat(' ', l:pad)
            \\endfunction
            \\
            \\" Regua superior da faixa de titulos: encaixa `┬` exatamente sobre cada divisor
            \\" vertical `│` dos titulos, alinhando com a rolagem horizontal da lista.
            \\function! s:lstf_ruler(width) abort
            \\  if empty(s:lstf_titles) | return repeat('─', a:width) | endif
            \\  let l:left = get(s:, 'lstf_leftcol', 0) - get(s:, 'lstf_id_width', 0)
            \\  let l:ruler = substitute(substitute(s:lstf_titles, '[^│]', '─', 'g'), '│', '┬', 'g')
            \\  let l:rest = strcharpart(l:ruler, max([0, l:left]))
            \\  let l:pad = max([0, a:width - strdisplaywidth(l:rest)])
            \\  return l:rest . repeat('─', l:pad)
            \\endfunction
            \\
            \\" Linha de moldura: caminho a esquerda, versao a direita, regua ligando
            \\" os dois -- a barra de titulo que o xpl-f desenha no topo da tela.
            \\" Volta em pedacos porque quem pinta e `matchaddpos`, por coluna de
            \\" byte: e conteudo de buffer, nao expressao de statusline.
            \\function! s:lstf_frame_parts(width) abort
            \\  let l:path = empty($LST_F_LOCATION) ? fnamemodify(getcwd(), ':~') : $LST_F_LOCATION
            \\  " 8 colunas sao a moldura fixa: '╭─ ', ' ', ' ' e ' ─╮'.
            \\  let l:avail = a:width - 8 - strdisplaywidth(s:lstf_identity)
            \\  if strdisplaywidth(l:path) > l:avail
            \\    let l:path = l:avail > 1 ? '…' . strcharpart(l:path, strchars(l:path) - l:avail + 1) : ''
            \\  endif
            \\  let l:fill = max([0, l:avail - strdisplaywidth(l:path)])
            \\  return ['╭─ ', l:path, ' ' . repeat('─', l:fill) . ' ', s:lstf_identity, ' ─╮']
            \\endfunction
            \\
            \\function! s:lstf_draw_frame() abort
            \\  if !exists('s:lstf_header_win') || win_id2win(s:lstf_header_win) == 0 | return | endif
            \\  let l:cur = win_getid()
            \\  noautocmd call win_gotoid(s:lstf_header_win)
            \\  let s:lstf_frame_width = winwidth(0)
            \\  let l:parts = s:lstf_frame_parts(s:lstf_frame_width)
            \\  let l:ruler = s:lstf_ruler(s:lstf_frame_width)
            \\  setlocal modifiable
            \\  " Linha 2 vazia e linha 3 a regua que fecha o topo da faixa de
            \\  " titulos com os encaixes `┬` -- que e a statusline desta mesma janela.
            \\  call setline(1, [join(l:parts, ''), '', l:ruler])
            \\  setlocal nomodifiable nomodified
            \\  " A linha inteira e moldura; caminho e versao vem por cima, com
            \\  " prioridade maior. Sem sintaxe: o texto e nosso e as colunas de
            \\  " byte ja sao conhecidas aqui.
            \\  call clearmatches()
            \\  call matchaddpos('LstfFrame', [[1], [3]], -5)
            \\  let l:spots = []
            \\  let l:at = len(l:parts[0]) + 1
            \\  if len(l:parts[1]) > 0 | call add(l:spots, [1, l:at, len(l:parts[1])]) | endif
            \\  let l:at += len(l:parts[1]) + len(l:parts[2])
            \\  if len(l:parts[3]) > 0 | call add(l:spots, [1, l:at, len(l:parts[3])]) | endif
            \\  if !empty(l:spots) | call matchaddpos('LstfPath', l:spots, 10) | endif
            \\  noautocmd call win_gotoid(l:cur)
            \\endfunction
            \\
            \\" Janela de tres linhas no topo: moldura, respiro e a regua que fecha o
            \\" topo da faixa de titulos, que e a statusline dela. Precisa ser
            \\" janela -- a `tabline` do Vim e uma linha so, e `winbar` nao existe
            \\" fora do Neovim.
            \\function! s:lstf_open_header() abort
            \\  if !s:lstf_frame || exists('s:lstf_header_win') | return | endif
            \\  " Terminal baixo demais nao tem onde por a janela: o split falharia
            \\  " com E36 e o erro tomaria a tela. Sem cabecalho, caminho e versao
            \\  " voltam para a barra de baixo.
            \\  if &lines < 7
            \\    let s:lstf_frame = 0
            \\    return
            \\  endif
            \\  let s:lstf_list_win = win_getid()
            \\  noautocmd topleft 3split __lstf_header__
            \\  let s:lstf_header_win = win_getid()
            \\  setlocal buftype=nofile bufhidden=wipe noswapfile nowrap
            \\  setlocal nonumber norelativenumber nocursorline winfixheight
            \\  setlocal statusline=%!LstfTitlesBar()
            \\  augroup lstf_header
            \\    autocmd! * <buffer>
            \\    autocmd WinEnter <buffer> call s:lstf_leave_header()
            \\  augroup END
            \\  noautocmd call win_gotoid(s:lstf_list_win)
            \\  call s:lstf_draw_frame()
            \\endfunction
            \\
            \\" O cursor nunca para no cabecalho: quem entrar volta para a lista.
            \\function! s:lstf_leave_header() abort
            \\  if winnr('$') > 1 | wincmd j | endif
            \\endfunction
            \\
            \\function! s:lstf_focus_list() abort
            \\  if exists('s:lstf_list_win') && win_id2win(s:lstf_list_win) > 0
            \\    call win_gotoid(s:lstf_list_win)
            \\  else
            \\    wincmd p
            \\  endif
            \\endfunction
            \\
            \\function! LstfStatusline() abort
            \\  let l:start = s:lstf_content_start()
            \\  let l:total = l:start > 0 ? len(filter(getline(l:start, '$'), 'v:val =~# ''^/\d\+\s\+''')) : 0
            \\  let l:current = l:start > 0 && line('.') >= l:start ? len(filter(getline(l:start, line('.')), 'v:val =~# ''^/\d\+\s\+''')) : 0
            \\  let l:mode = mode(1) =~# '^[iR]' ? 'EDIT' : mode(1) =~# '^[vV]' ? 'VISUAL' : 'NORMAL'
            \\  let l:name = substitute(s:lstf_entry_path(), '%', '%%', 'g')
            \\  let l:location = empty($LST_F_LOCATION) ? fnamemodify(getcwd(), ':~') : $LST_F_LOCATION
            \\  let l:location = substitute(l:location, '%', '%%', 'g')
            \\  let l:editor = has('nvim') ? 'Neovim' : 'Vim'
            \\  " A pasta corrente fica junto do nome, nao na outra ponta da barra:
            \\  " as duas metades do caminho sob o cursor se leem de uma vez. O
            \\  " `%<` poe a truncagem no caminho: em terminal estreito o modo e o
            \\  " contador ficam, e o comeco do caminho e que some.
            \\  " Com a moldura no topo o caminho e a versao ja estao na tela: aqui
            \\  " embaixo sobrariam so tirando espaco do nome sob o cursor.
            \\  let l:where = s:lstf_frame ? l:name : l:location . (empty(l:name) ? '' : '  ' . l:name)
            \\  let l:tag = s:lstf_frame ? '' : s:lstf_identity . '  ·  '
            \\  let l:aviso = empty(s:lstf_notice) ? '' : '%#LstfStatusNotice# ' . substitute(s:lstf_notice, '%', '%%', 'g') . ' %#LstfStatusInfo#'
            \\  return '%#LstfStatusMode# ' . l:mode . ' %#LstfStatusInfo# ' . l:current . '/' . l:total . ' ' . l:aviso . ' %<' . l:where . '%=%#LstfStatusInfo# ' . l:tag . l:editor . ' %#LstfStatusHelp# F1=Help '
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
            \\    call s:lstf_draw_frame()
            \\    return
            \\  endif
            \\  " Pelo nome, nao por `buftype`: a janela de cabecalho tambem e
            \\  " nofile e seria fechada no lugar do painel.
            \\  for l:w in range(1, winnr('$'))
            \\    if bufname(winbufnr(l:w)) ==# '__lstf_dest_panel__'
            \\      execute l:w . 'close'
            \\      call s:lstf_draw_frame()
            \\      return
            \\    endif
            \\  endfor
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
            \\  nnoremap <buffer> <silent> q :call <SID>lstf_focus_list()<Bar>call LstfQuit()<CR>
            \\  nnoremap <buffer> <silent> <Esc> :close<Bar>call <SID>lstf_draw_frame()<CR>
            \\  nnoremap <buffer> <silent> <Tab> :call <SID>lstf_focus_list()<CR>
            \\  nnoremap <buffer> <silent> <F1> :call LstfHelp()<CR>
            \\  nnoremap <buffer> <silent> ? :call LstfHelp()<CR>
            \\  call s:lstf_render_dest(getcwd())
            \\  " O split estreitou a janela da lista sem passar por ela, entao a
            \\  " barra de topo ficaria descrevendo a largura antiga.
            \\  let l:dest = win_getid()
            \\  call s:lstf_focus_list()
            \\  call s:lstf_follow_scroll()
            \\  call s:lstf_draw_frame()
            \\  call win_gotoid(l:dest)
            \\endfunction
            \\
            \\function! s:lstf_tab_jump() abort
            \\  if exists('t:lstf_dest_win') && win_id2win(t:lstf_dest_win) > 0
            \\    call win_gotoid(t:lstf_dest_win)
            \\  else
            \\    call LstfToggleSplit()
            \\  endif
            \\endfunction
            \\
            \\" Sem isto o Vim so enxerga o lado cterm e as cores em hex ficam
            \\" decorativas. O servidor, que nao anuncia truecolor, segue no cterm.
            \\if has('termguicolors') && !has('gui_running') && ($COLORTERM ==# 'truecolor' || $COLORTERM ==# '24bit')
            \\  set termguicolors
            \\endif
            \\highlight LstfStatusMode cterm=bold ctermfg=0 ctermbg=12 gui=bold guifg=#1e1e2e guibg=#89b4fa
            \\highlight LstfStatusInfo ctermfg=7 ctermbg=NONE guifg=#cdd6f4 guibg=NONE
            \\highlight LstfStatusHelp cterm=bold ctermfg=0 ctermbg=12 gui=bold guifg=#1e1e2e guibg=#89b4fa
            \\highlight LstfStatusNotice cterm=bold ctermfg=0 ctermbg=11 gui=bold guifg=#1e1e2e guibg=#f9e2af
            \\" Faixa dos titulos, moldura e caminho: a grade do xpl-f. A regua de baixo e o sublinhado na cor da moldura.
            \\highlight LstfTitles cterm=bold,underline ctermfg=15 ctermbg=236 gui=bold,underline guifg=#cdd6f4 guibg=#2a2b3c guisp=#6c7086
            \\highlight LstfFrame ctermfg=245 guifg=#6c7086 guibg=NONE
            \\highlight LstfPath cterm=bold ctermfg=11 gui=bold guifg=#f9e2af guibg=NONE
            \\highlight LstfTitlesSep cterm=underline ctermfg=245 ctermbg=236 gui=underline guifg=#6c7086 guibg=#2a2b3c guisp=#6c7086
            \\highlight LstfSep ctermfg=245 guifg=#6c7086 guibg=NONE
            \\highlight CursorLine cterm=NONE ctermbg=240 gui=NONE guibg=#45475a
            \\" Cores por natureza da entrada, as mesmas do xpl-f. O par cterm
            \\" nao e enfeite: servidor sem truecolor so enxerga esse lado.
            \\highlight LstfDir cterm=bold ctermfg=12 gui=bold guifg=#61afef
            \\highlight LstfExec cterm=bold ctermfg=10 gui=bold guifg=#a6d189
            \\highlight LstfLink ctermfg=14 gui=italic guifg=#56b6c2
            \\highlight LstfFile ctermfg=252 guifg=#c0caf5
            \\set laststatus=2
            \\setlocal statusline=%!LstfStatusline()
            \\set noshowmode showtabline=0
            \\set shortmess+=F
            \\if exists('+fillchars')
            \\  execute "setlocal fillchars+=eob:\\ "
            \\endif
            \\set noruler noshowcmd
            \\setlocal nonumber norelativenumber nowrap sidescrolloff=8 cursorline cursorlineopt=line
            \\syntax match LstfInternalId /^\/\d\+\s\+/ conceal
            \\syntax match LstfSep /│/ contained
            \\" O sequencial e metadado interno: oculta-lo tambem na linha do
            \\" cursor evita deslocar as colunas, inclusive ao voltar do :find.
            \\setlocal conceallevel=2 concealcursor=nvic
            \\" A linha inteira e um item por natureza, com o ID e os divisores
            \\" contidos nele. Ancorar nos cinco divisores, e nao em contagem de
            \\" caracteres, e o que deixa o nome com `│` dentro ainda cair no
            \\" grupo certo. LstfExec vem depois de LstfFile de proposito: entre
            \\" itens que comecam na mesma coluna, o Vim da prioridade ao definido
            \\" por ultimo.
            \\syntax match LstfFile /^\/\d\+\s\+[-?]\%( │ [^│]*\)\{4} │  .*$/ contains=LstfInternalId,LstfSep
            \\syntax match LstfExec /^\/\d\+\s\+- │ [^│]*x[^│]*\%( │ [^│]*\)\{3} │  .*$/ contains=LstfInternalId,LstfSep
            \\syntax match LstfDir /^\/\d\+\s\+d\%( │ [^│]*\)\{4} │  .*$/ contains=LstfInternalId,LstfSep
            \\syntax match LstfLink /^\/\d\+\s\+l\%( │ [^│]*\)\{4} │  .*$/ contains=LstfInternalId,LstfSep
            \\augroup lstf_buffer
            \\  autocmd! * <buffer>
            \\  autocmd BufWritePre <buffer> call s:lstf_prepare_save()
            \\  autocmd TextChanged <buffer> call s:lstf_restore_header()
            \\  autocmd CursorMoved <buffer> call s:lstf_keep_cursor_below_header()
            \\  autocmd CursorMoved,CursorMovedI <buffer> call s:lstf_keep_cursor_in_name()
            \\  autocmd CursorMoved,CursorMovedI <buffer> call s:lstf_follow_scroll()
            \\  autocmd WinEnter,BufEnter,VimResized <buffer> call s:lstf_follow_scroll()
            \\  autocmd TextChanged,InsertLeave <buffer> call s:lstf_restore_columns()
            \\  autocmd InsertLeave <buffer> call s:lstf_restore_header()
            \\  " O painel de destino pode estar aberto: `quit` fecharia so a
            \\  " janela da lista e deixaria o processo Vim preso no painel.
            \\  autocmd BufWritePost <buffer> quitall
            \\augroup END
            \\augroup lstf_statusline
            \\  autocmd!
            \\  autocmd ModeChanged * redrawstatus
            \\  " Abrir o painel de destino estreita a janela da lista sem passar
            \\  " por ela: sem isto a barra de topo so voltaria a sincronizar no
            \\  " proximo Tab. Vim antigo nao tem o evento; ai sincroniza no Tab.
            \\  if exists('##WinScrolled')
            \\    autocmd WinScrolled * if exists('b:lstf_id_width') | call s:lstf_follow_scroll() | endif
            \\  endif
            \\  " A moldura e texto de buffer: nao se reajusta sozinha na largura nova.
            \\  autocmd VimResized * call s:lstf_draw_frame()
            \\augroup END
            \\" Recarga da sessao viva: o pai regravou buffer e estado; aqui so
            \\" falta sincronizar a tela com o que mudou -- sem reabrir nada.
            \\function! s:lstf_restore_cursor() abort
            \\  let l:start = s:lstf_content_start()
            \\  let l:landed = 0
            \\  if filereadable($LST_F_STATE . '/cursor_name')
            \\    " Volta de subida: pousa na entrada com o nome do diretorio de
            \\    " onde se veio. Nome, nao offset: sobrevive a :sort. One-shot.
            \\    let l:name = get(readfile($LST_F_STATE . '/cursor_name'), 0, '')
            \\    call delete($LST_F_STATE . '/cursor_name')
            \\    if !empty(l:name) && l:start > 0
            \\      for l:lnum in range(l:start, line('$'))
            \\        let l:p = s:lstf_entry_path(getline(l:lnum))
            \\        if substitute(l:p, '/$', '', '') ==# l:name
            \\          call cursor(l:lnum, 1)
            \\          let l:landed = 1
            \\          break
            \\        endif
            \\      endfor
            \\    endif
            \\  endif
            \\  if !l:landed
            \\    if filereadable($LST_F_STATE . '/cursor')
            \\      let l:offset = get(readfile($LST_F_STATE . '/cursor'), 0, '0')
            \\      if l:start > 0
            \\        execute 'call cursor(' . (l:start + l:offset) . ', 1)'
            \\      endif
            \\    elseif l:start > 0
            \\      call cursor(l:start, 1)
            \\    endif
            \\  endif
            \\endfunction
            \\
            \\function! s:lstf_after_reload() abort
            \\  if filereadable($LST_F_STATE . '/base')
            \\    let l:newbase = get(readfile($LST_F_STATE . '/base'), 0, '')
            \\    if !empty(l:newbase)
            \\      silent! execute 'cd ' . fnameescape(l:newbase)
            \\    endif
            \\  endif
            \\  if filereadable($LST_F_STATE . '/location')
            \\    let $LST_F_LOCATION = get(readfile($LST_F_STATE . '/location'), 0, '')
            \\  endif
            \\  if filereadable($LST_F_STATE . '/header')
            \\    let b:lstf_header = readfile($LST_F_STATE . '/header')
            \\    call s:lstf_restore_header()
            \\    " Cabecalho ocupando o buffer todo: sem uma linha abaixo dele nao
            \\    " havia onde pousar o cursor para digitar o primeiro nome.
            \\    if line('$') <= len(b:lstf_header) | call append('$', '') | endif
            \\    setlocal nomodified
            \\  endif
            \\  let s:lstf_notice = filereadable($LST_F_STATE . '/notice')
            \\    \ ? get(readfile($LST_F_STATE . '/notice'), 0, '') : ''
            \\  call s:lstf_capture_prefixes()
            \\  let b:lstf_entry_lines = s:lstf_entry_lines()
            \\  call s:lstf_follow_scroll()
            \\  call s:lstf_restore_cursor()
            \\endfunction
            \\
            \\call s:lstf_after_reload()
            \\" A ajuda pode manter o foco em um popup ou painel auxiliar. Como esta
            \\" instancia do Vim e exclusiva do lst-f, F1 e global para nunca deixar
            \\" o Vim abrir :help em um split e alterar a tela controlada.
            \\nnoremap <silent> <F1> :call LstfHelp()<CR>
            \\nnoremap <buffer> <silent> ? :call LstfHelp()<CR>
            \\nnoremap <buffer> <silent> <CR> :call LstfOpen()<CR>
            \\nnoremap <buffer> <silent> . :call LstfToggleHidden()<CR>
            \\nnoremap <buffer> <silent> - :call LstfUp()<CR>
            \\nnoremap <buffer> <silent> <lt> :call LstfBack()<CR>
            \\nnoremap <buffer> <silent> > :call LstfForward()<CR>
            \\nnoremap <buffer> <silent> <Bslash> :call LstfTree()<CR>
            \\nnoremap <buffer> <silent> <C-p> :call LstfFind()<CR>
            \\nnoremap <buffer> <silent> <C-s> :call LstfToggleSplit()<CR>
            \\nnoremap <buffer> <silent> <Tab> :call <SID>lstf_tab_jump()<CR>
            \\nnoremap <buffer> <silent> q :call LstfQuit()<CR>
            \\nnoremap <buffer> <silent> ZZ :call LstfQuit()<CR>
            \\cnoreabbrev <expr> <buffer> q getcmdtype() ==# ':' && getcmdline() ==# 'q' ? 'call LstfQuit()' : 'q'
            \\cnoreabbrev <expr> <buffer> quit getcmdtype() ==# ':' && getcmdline() ==# 'quit' ? 'call LstfQuit()' : 'quit'
            \\" Por ultimo: abrir o split antes daqui faria os `setlocal` e os
            \\" mapeamentos `<buffer>` acima cairem no buffer errado.
            \\call s:lstf_open_header()
            \\redrawstatus | echo ''
            \\
        );
        try w.flush();
    }
};
