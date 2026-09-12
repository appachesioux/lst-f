//! Estado compartilhado entre o processo principal e o self-exec de preview
//! que o fzf dispara (`--preview-index`).
//!
//! Nao confundir com a **area de sessao** do `fsops`: aquela e `.lst-f-<pid>/`
//! no diretorio-base, no mesmo filesystem, e existe para o rollback da
//! remocao. Esta aqui e um diretorio de trabalho volatil, e existe so para que
//! nenhum caminho precise ser interpolado em linha de comando de shell: os
//! filhos recebem o caminho deste diretorio pela variavel `LST_F_STATE`.

const std = @import("std");
const explorer = @import("explorer.zig");
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
            \\" A busca do Vim segue a mesma regra do fzf: minusculas ignoram
            \\" caixa; uma maiuscula torna a consulta sensivel a caixa.
            \\set ignorecase smartcase incsearch
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
            \\    \ '  • Antes de aplicar, um popup mostra a lista completa de alteracoes',
            \\    \ '  • :w sem edicao apenas atualiza a lista e mantem a sessao aberta',
            \\    \ '  • Apague a linha  : remove a entrada (area de sessao temporaria)',
            \\    \ '  • Nome em linha nova: cria arquivo ( / no fim cria diretorio)',
            \\    \ '  • nome -> alvo    : cria symlink ( nome => alvo cria hardlink)',
            \\    \ '  • So o nome e editavel: cabecalho e colunas voltam sozinhos',
            \\    \ '  • /0000 oculto    : vincula a linha (:sort e reordenar sao seguros)',
            \\    \ '',
            \\    \ '  Diretivas (escreva no buffer e salve):',
            \\    \ '    :cd [dir]      Entra no diretorio (.. sobe, sem arg ou ~ vai para HOME)',
            \\    \ '    :home          Vai direto para o diretorio HOME (~)',
            \\    \ '    :find [termo]  Busca recursiva fuzzy na arvore com fzf',
            \\    \ '    :sh [dir]      Abre terminal / shell no diretorio (:shell, :terminal)',
            \\    \ '    :ln <alvo> [n] Cria symlink para o alvo (:link, :symlink, :hardlink)',
            \\    \ '    :hidden        Alterna exibicao de arquivos ocultos',
            \\    \ '    :theme [modo]  Alterna ou define tema: light ou dark (:light, :dark)',
            \\    \ '    :back/:forward Andam pelos diretorios visitados na sessao',
            \\    \ '    :undo          Desfaz a ultima operacao aplicada na sessao',
            \\    \ '    :quit          Sai da sessao (:cq aborta sem aplicar nada)',
            \\    \ '',
            \\    \ '  Atalhos no buffer:',
            \\    \ '    .              Alterna exibicao de arquivos ocultos',
            \\    \ '    ~ ou gh        Vai direto para o diretorio HOME (~)',
            \\    \ '    Ctrl+P         Abre a busca fuzzy (fzf) na arvore inteira',
            \\    \ '    Ctrl+A         Seleciona todo o buffer',
            \\    \ '    Enter          Abre arquivo ou entra no diretorio da linha',
            \\    \ '    -              Sobe para o diretorio-pai',
            \\    \ '    r ou Ctrl+R    Recarrega (refresh) a lista atual',
            \\    \ '    yr ou yp       Copia caminho relativo para o clipboard',
            \\    \ '    ya             Copia caminho absoluto para o clipboard',
            \\    \ '    < e >          Voltam e avancam nos diretorios visitados',
            \\    \ '    \              Mostra a arvore visual do diretorio',
            \\    \ '    F2 ou cob      Alterna entre tema claro e escuro (light/dark)',
            \\    \ '    F4             Abre terminal / shell no diretorio atual',
            \\    \ '    Ctrl+S         Abre esta pasta numa segunda janela (:vsplit)',
            \\    \ '    Tab            Percorre as janelas abertas',
            \\    \ '    yy / y         Copia a linha (o ID vai junto, oculto)',
            \\    \ '    dd             Apaga a linha: remove, ou recorta para colar',
            \\    \ '    p              Cola neste diretorio: yy antes = copia,',
            \\    \ '                   dd antes = move (salve a janela onde colou)',
            \\    \ '                   nome em conflito mostra o desfecho na linha',
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
            \\    if l:line =~# '^[:#]' || l:line =~# '^\s*$' | return '' | endif
            \\    let l:raw = substitute(substitute(l:line, '^\s*', '', ''), '\s*$', '', '')
            \\    let l:arrow = match(l:raw, '\s->\s\|\s=>\s')
            \\    return l:arrow >= 0 ? substitute(strpart(l:raw, 0, l:arrow), '\s*$', '', '') : l:raw
            \\  endif
            \\  let l:start = s:lstf_name_start(l:line)
            \\  if l:start > 0
            \\    return strpart(l:line, l:start)
            \\  endif
            \\  let l:body = substitute(l:line, '^/\d\+\s\+', '', '')
            \\  let l:sep = strridx(l:body, ' │ ')
            \\  if l:sep >= 0
            \\    let l:res = strpart(l:body, l:sep + 5)
            \\    return substitute(l:res, '^\s*\S*\s*', '', '')
            \\  endif
            \\  let l:sep2 = stridx(l:body, '  │  ')
            \\  if l:sep2 >= 0
            \\    return strpart(l:body, l:sep2 + 7)
            \\  endif
            \\  return l:body
            \\endfunction
            \\
            \\function! s:lstf_set_clipboard(text) abort
            \\  let @" = a:text
            \\  " Vim sem +clipboard nao tem os registros @+ e @*: E354.
            \\  if has('clipboard')
            \\    let @+ = a:text
            \\    let @* = a:text
            \\  endif
            \\  if executable('wl-copy') && (!empty($WAYLAND_DISPLAY) || !empty($WAYLAND_SOCKET))
            \\    call system('wl-copy', a:text)
            \\  elseif executable('xclip') && !empty($DISPLAY)
            \\    call system('xclip -selection clipboard', a:text)
            \\  elseif executable('xsel') && !empty($DISPLAY)
            \\    call system('xsel --clipboard --input', a:text)
            \\  elseif executable('pbcopy')
            \\    call system('pbcopy', a:text)
            \\  elseif executable('clip.exe')
            \\    call system('clip.exe', a:text)
            \\  elseif executable('wl-copy')
            \\    call system('wl-copy', a:text)
            \\  endif
            \\endfunction
            \\
            \\function! LstfYank(...) abort
            \\  let l:abs = a:0 > 0 ? a:1 : 0
            \\  let l:entry = s:lstf_entry_path()
            \\  if empty(l:entry)
            \\    return
            \\  endif
            \\  if l:abs
            \\    let l:loc = s:lstf_location()
            \\    let l:path = simplify(l:loc . '/' . l:entry)
            \\  else
            \\    let l:path = l:entry
            \\  endif
            \\  call s:lstf_set_clipboard(l:path)
            \\  let b:lstf_notice = 'caminho copiado: ' . l:path
            \\  redrawstatus!
            \\endfunction
            \\
            \\function! s:lstf_yank_visual(abs) range abort
            \\  let l:paths = []
            \\  let l:loc = s:lstf_location()
            \\  for l:lnum in range(a:firstline, a:lastline)
            \\    let l:entry = s:lstf_entry_path(getline(l:lnum))
            \\    if empty(l:entry) | continue | endif
            \\    if a:abs
            \\      call add(l:paths, simplify(l:loc . '/' . l:entry))
            \\    else
            \\      call add(l:paths, l:entry)
            \\    endif
            \\  endfor
            \\  if !empty(l:paths)
            \\    let l:text = join(l:paths, "\n")
            \\    call s:lstf_set_clipboard(l:text)
            \\    let b:lstf_notice = len(l:paths) == 1 ? ('caminho copiado: ' . l:paths[0]) : (len(l:paths) . ' caminhos copiados')
            \\    redrawstatus!
            \\  endif
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
            \\    let b:lstf_notice = 'aberto via xdg-open'
            \\    redrawstatus!
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
            \\" Diretorio deste buffer. E a ancora unica de tudo que acontece
            \\" aqui dentro: caminho relativo, destino de copia, moldura, cwd.
            \\" Por buffer, nunca global -- com duas janelas abertas nao existe
            \\" "o" diretorio corrente, existe o de cada uma.
            \\function! s:lstf_dir() abort
            \\  if exists('b:lstf_dir') && !empty(b:lstf_dir) | return b:lstf_dir | endif
            \\  if filereadable($LST_F_STATE . '/base')
            \\    return get(readfile($LST_F_STATE . '/base'), 0, '')
            \\  endif
            \\  return getcwd()
            \\endfunction
            \\
            \\" Sidecar deste buffer: o pai grava `<arquivo>.dir`, `.location` e
            \\" `.header` ao lado do conteudo. Tenta o nome como o Vim o guarda e
            \\" a forma absoluta, porque o caminho de estado pode vir relativo.
            \\function! s:lstf_sidecar(ext) abort
            \\  let l:name = bufname('%')
            \\  if empty(l:name) | return '' | endif
            \\  if filereadable(l:name . a:ext) | return l:name . a:ext | endif
            \\  let l:abs = fnamemodify(l:name, ':p') . a:ext
            \\  if filereadable(l:abs) | return l:abs | endif
            \\  return ''
            \\endfunction
            \\
            \\" Caminho para exibicao (home abreviado, sufixo de ocultos). Tambem
            \\" por buffer: a moldura e a barra de cada janela descrevem a sua
            \\" propria pasta, nao a que o pai visitou por ultimo.
            \\function! s:lstf_location() abort
            \\  if exists('b:lstf_location') && !empty(b:lstf_location)
            \\    return b:lstf_location
            \\  endif
            \\  return empty($LST_F_LOCATION) ? getcwd() : $LST_F_LOCATION
            \\endfunction
            \\
            \\" Pedido ao laco vivo. O diretorio de quem pede vai por ambiente,
            \\" nunca por argv: caminho de arquivo e dado hostil para interpolar
            \\" em linha de comando. Devolve [exit_code, saida].
            \\function! s:lstf_live(cmd) abort
            \\  let $LST_F_LIVE_DIR = s:lstf_dir()
            \\  let l:out = system($LST_F_SELF . ' --client ' . a:cmd)
            \\  let l:err = v:shell_error
            \\  unlet! $LST_F_LIVE_DIR
            \\  return [l:err, substitute(l:out, "\n\\+$", '', '')]
            \\endfunction
            \\
            \\" Navegacao viva: o pai relista, regrava e responde com o caminho do
            \\" buffer que esta janela deve mostrar. Navegar pode trocar de buffer
            \\" -- e o que permite dois diretorios lado a lado, cada janela no seu,
            \\" sem um "painel de destino" de categoria separada. Com edicao
            \\" pendente, o caminho e a diretiva antiga: ela passa pela
            \\" confirmacao antes de qualquer coisa.
            \\function! s:lstf_nav(cmd, directive) abort
            \\  if &modified
            \\    call s:lstf_write_directive(a:directive)
            \\    return
            \\  endif
            \\  let [l:err, l:out] = s:lstf_live(a:cmd)
            \\  if l:err
            \\    let b:lstf_notice = l:out
            \\    redrawstatus!
            \\    return
            \\  endif
            \\  call s:lstf_show_buffer(l:out)
            \\endfunction
            \\
            \\" Todos os buffers de diretorio gravados no disco, menos o corrente
            \\" (que vai pelo `proposal` ou pelo proprio `:w`). E o que deixa o
            \\" laco enxergar o que esta pendente em cada janela: com isso o `dd`
            \\" numa e o `p` na outra viram um movimento, porque o laco compara o
            \\" texto dos dois buffers em vez de consultar um registro de recorte
            \\" paralelo. Sem gravar, o arquivo no disco ainda teria a linha que o
            \\" usuario acabou de apagar na tela.
            \\function! s:lstf_flush_buffers() abort
            \\  for l:info in getbufinfo({'bufloaded': 1})
            \\    if l:info.bufnr == bufnr('%') | continue | endif
            \\    if l:info.name !~# '\.lstf$' | continue | endif
            \\    if !l:info.changed | continue | endif
            \\    call writefile(getbufline(l:info.bufnr, 1, '$'), l:info.name, 'b')
            \\  endfor
            \\endfunction
            \\
            \\" Recarrega as janelas que mostram um buffer que a aplicacao mexeu --
            \\" a pasta de onde saiu um movimento. Vem na resposta do laco, uma por
            \\" linha depois do buffer desta janela; nenhuma outra e tocada, para
            \\" nao apagar edicao pendente de quem nao entrou na operacao.
            \\function! s:lstf_reload_others(paths) abort
            \\  if !exists('*win_findbuf') | return | endif
            \\  let l:cur = win_getid()
            \\  for l:p in a:paths
            \\    if empty(l:p) | continue | endif
            \\    let l:nr = bufnr(l:p)
            \\    if l:nr <= 0 | continue | endif
            \\    for l:w in win_findbuf(l:nr)
            \\      if l:w == l:cur | continue | endif
            \\      noautocmd call win_gotoid(l:w)
            \\      " Este reload acontece dentro de um autocmd (BufWritePost), e
            \\      " autocmd aninhado nao dispara sem `nested`: o `BufReadPost`
            \\      " que monta o buffer nao vem sozinho. A flag diz se veio.
            \\      let s:lstf_opened = 0
            \\      silent! edit!
            \\      if !s:lstf_opened | call s:lstf_open_buffer() | endif
            \\    endfor
            \\  endfor
            \\  noautocmd call win_gotoid(l:cur)
            \\endfunction
            \\
            \\" Abre nesta janela o buffer que o pai acabou de gravar. Caminho igual
            \\" ao atual: `edit!` so rele o arquivo. Caminho novo: o `BufReadPost`
            \\" monta o buffer (opcoes, sintaxe, mapas e comandos locais) antes do
            \\" reload, exatamente como fez na abertura. Depois da primeira linha
            \\" vem a lista de buffers de outras janelas que tambem mudaram.
            \\function! s:lstf_show_buffer(reply) abort
            \\  let l:linhas = split(a:reply, "\n")
            \\  let l:target = get(l:linhas, 0, '')
            \\  call s:lstf_reload_others(l:linhas[1:])
            \\  " Depois do reload das outras: a flag e de quem esta sendo aberto
            \\  " agora, e cada reload la dentro mexe nela.
            \\  let s:lstf_opened = 0
            \\  if !empty(l:target) && filereadable(l:target)
            \\    \ && fnamemodify(bufname('%'), ':p') !=# fnamemodify(l:target, ':p')
            \\    silent! execute 'edit! ' . fnameescape(l:target)
            \\  else
            \\    silent! edit!
            \\  endif
            \\  if !s:lstf_opened | call s:lstf_open_buffer() | endif
            \\endfunction
            \\
            \\function! LstfUp() abort
            \\  call s:lstf_nav('up', ':cd ..')
            \\endfunction
            \\
            \\function! LstfCd(dir) abort
            \\  let l:target = empty(a:dir) ? '~' : a:dir
            \\  let $LST_F_LIVE_ARG = l:target
            \\  call s:lstf_nav('enter', ':cd ' . l:target)
            \\  unlet $LST_F_LIVE_ARG
            \\endfunction
            \\
            \\function! LstfHome() abort
            \\  call s:lstf_nav('home', ':home')
            \\endfunction
            \\
            \\function! s:lstf_cmd_find(query) abort
            \\  let l:dir = empty(a:query) ? ':find' : ':find ' . a:query
            \\  call s:lstf_write_directive(l:dir)
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
            \\function! LstfShell(...) abort
            \\  let l:dir = a:0 > 0 && !empty(a:1) ? a:1 : ''
            \\  call s:lstf_write_directive(empty(l:dir) ? ':sh' : ':sh ' . l:dir)
            \\endfunction
            \\
            \\function! LstfToggleHidden() abort
            \\  call s:lstf_nav('hidden', ':hidden')
            \\endfunction
            \\
            \\function! LstfToggleTheme(...) abort
            \\  let l:target = a:0 > 0 && !empty(a:1) ? tolower(a:1) : 'toggle'
            \\  if l:target ==# 'light'
            \\    let &background = 'light'
            \\  elseif l:target ==# 'dark'
            \\    let &background = 'dark'
            \\  elseif l:target ==# 'toggle'
            \\    let &background = (&background ==# 'light' ? 'dark' : 'light')
            \\  else
            \\    echoerr 'Uso: :theme [light|dark|toggle]'
            \\    return
            \\  endif
            \\  call s:lstf_apply_colors()
            \\  if exists('$LST_F_STATE') && isdirectory($LST_F_STATE)
            \\    call writefile([&background], $LST_F_STATE . '/theme')
            \\  endif
            \\  if exists('$LST_F_SELF') && filereadable($LST_F_SELF) && exists('$LST_F_STATE') && filereadable($LST_F_STATE . '/live.sock')
            \\    let $LST_F_LIVE_ARG = &background
            \\    silent! call system($LST_F_SELF . ' --client theme')
            \\    unlet! $LST_F_LIVE_ARG
            \\  endif
            \\  redraw!
            \\  redrawstatus!
            \\  echo 'Tema: ' . &background
            \\endfunction
            \\
            \\
            \\function! s:lstf_confirm_plan(plan) abort
            \\  let l:lines = [''] + a:plan + ['',
            \\    \ '  y ou Enter  aplica    n ou Esc  cancela    j/k  rolam', '']
            \\  " Vim/Neovim antigos ou terminais minimos conservam uma saida
            \\  " textual; a aplicacao nunca depende do popup para ser segura.
            \\  if &columns < 30 || &lines < 9 || (!has('nvim') && !exists('*popup_create'))
            \\    echo join(l:lines, "\n")
            \\    let l:answer = input('Apply filesystem changes? [y/N] ')
            \\    return tolower(l:answer) ==# 'y' || tolower(l:answer) ==# 'yes'
            \\  endif
            \\  let l:width = 50
            \\  for l:line in l:lines
            \\    let l:width = max([l:width, strdisplaywidth(l:line) + 4])
            \\  endfor
            \\  let l:width = min([l:width, &columns - 4])
            \\  let l:height = min([len(l:lines), &lines - 6])
            \\  let l:buf = -1
            \\  if has('nvim')
            \\    let l:buf = nvim_create_buf(v:false, v:true)
            \\    call nvim_buf_set_lines(l:buf, 0, -1, v:true, l:lines)
            \\    let l:win = nvim_open_win(l:buf, v:false, {
            \\      \ 'relative': 'editor',
            \\      \ 'row': max([1, (&lines - l:height) / 2 - 1]),
            \\      \ 'col': max([1, (&columns - l:width) / 2]),
            \\      \ 'width': l:width,
            \\      \ 'height': l:height,
            \\      \ 'style': 'minimal',
            \\      \ 'border': 'rounded',
            \\      \ 'title': ' Confirmar alteracoes ',
            \\      \ 'title_pos': 'center'
            \\    \ })
            \\  else
            \\    let l:win = popup_create(l:lines, {
            \\      \ 'title': ' Confirmar alteracoes ',
            \\      \ 'border': [],
            \\      \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
            \\      \ 'padding': [0, 1, 0, 1],
            \\      \ 'pos': 'center',
            \\      \ 'minwidth': l:width,
            \\      \ 'maxwidth': l:width,
            \\      \ 'minheight': l:height,
            \\      \ 'maxheight': l:height,
            \\      \ 'mapping': 0,
            \\      \ 'close': 'none'
            \\    \ })
            \\  endif
            \\  redraw
            \\  let l:approved = 0
            \\  while 1
            \\    let l:key = exists('*getcharstr') ? getcharstr() : nr2char(getchar())
            \\    if l:key ==# 'y' || l:key ==# 'Y' || l:key ==# "\<CR>"
            \\      let l:approved = 1
            \\      break
            \\    elseif l:key ==# 'n' || l:key ==# 'N' || l:key ==# 'q' || l:key ==# "\<Esc>"
            \\      break
            \\    elseif l:key ==# 'j' || l:key ==# "\<Down>"
            \\      silent! call win_execute(l:win, 'normal! j')
            \\    elseif l:key ==# 'k' || l:key ==# "\<Up>"
            \\      silent! call win_execute(l:win, 'normal! k')
            \\    endif
            \\    redraw
            \\  endwhile
            \\  if has('nvim')
            \\    silent! call nvim_win_close(l:win, v:true)
            \\    if l:buf >= 0 | silent! call nvim_buf_delete(l:buf, {'force': v:true}) | endif
            \\  else
            \\    silent! call popup_close(l:win)
            \\  endif
            \\  redraw
            \\  return l:approved
            \\endfunction
            \\
            \\" Recusar o `:w` sem sujar a tela. O que aborta um BufWritePre e a
            \\" excecao, mas `throw` sai como E605 mais o traceback do autocmd em
            \\" vermelho e um `Press ENTER` -- tres linhas de ruido tapando o aviso
            \\" que a barra acabou de receber, para um desfecho normal e previsto.
            \\" Medido: interrupt() aborta igual (arquivo intacto, BufWritePost nao
            \\" roda) e nao imprime nada. E de Vim 8.0.0140, abaixo do piso, mas vai
            \\" por feature-detect como o resto; o throw fica de reserva.
            \\function! s:lstf_abort_save() abort
            \\  if exists('*interrupt')
            \\    call interrupt()
            \\  endif
            \\  throw 'lst-f: operation cancelled'
            \\endfunction
            \\
            \\function! s:lstf_prepare_save() abort
            \\  call delete($LST_F_STATE . '/approved')
            \\  let l:is_quitting = search('^:quit', 'nw') > 0
            \\  let l:entries = s:lstf_entry_lines()
            \\  if exists('b:lstf_entry_lines') && l:entries !=# b:lstf_entry_lines
            \\    call s:lstf_flush_buffers()
            \\    call writefile(getline(1, '$'), $LST_F_STATE . '/proposal', 'b')
            \\    let [l:perr, l:out] = s:lstf_live('preview')
            \\    if l:perr == 0
            \\      let l:plan = filereadable($LST_F_STATE . '/preview')
            \\        \ ? readfile($LST_F_STATE . '/preview') : []
            \\      if !empty(l:plan)
            \\        if !s:lstf_confirm_plan(l:plan)
            \\          if l:is_quitting
            \\            return
            \\          endif
            \\          call s:lstf_abort_save()
            \\        endif
            \\      endif
            \\    elseif l:perr == 2
            \\      let l:answer = input('Apply filesystem changes? [y/N] ')
            \\      if tolower(l:answer) !=# 'y' && tolower(l:answer) !=# 'yes'
            \\        if l:is_quitting
            \\          return
            \\        endif
            \\        call s:lstf_abort_save()
            \\      endif
            \\    else
            \\      let b:lstf_notice = substitute(l:out, "\n\\+$", '', '')
            \\      redrawstatus!
            \\      if l:is_quitting
            \\        return
            \\      endif
            \\      call s:lstf_abort_save()
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
            \\function! s:lstf_after_save() abort
            \\  let l:directives = filter(getline(1, '$'), 'v:val =~# "^:"')
            \\  " Operacoes comuns e :refresh usam a sessao viva. Diretivas que
            \\  " abrem outra interface (:find, :open...) continuam pela volta
            \\  " externa, pois precisam tomar conta do terminal.
            \\  if len(l:directives) == 1 && l:directives[0] ==# ':refresh'
            \\    call s:lstf_flush_buffers()
            \\    let [l:aerr, l:out] = s:lstf_live('apply')
            \\    if l:aerr == 0
            \\      call s:lstf_show_buffer(l:out)
            \\      redraw
            \\      return
            \\    endif
            \\    " Codigo 2 significa que o socket nao estava disponivel: o
            \\    " laco antigo ainda consegue aplicar o arquivo que foi salvo.
            \\    if l:aerr != 2
            \\      setlocal modified
            \\      let b:lstf_notice = l:out
            \\      redrawstatus!
            \\      return
            \\    endif
            \\  endif
            \\  quitall
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
            \\  return matchend(a:line, '^\/\d\+\s\+\%(.*│\s*\S*\s\+\)\?')
            \\endfunction
            \\
            \\" So o nome e editavel. As colunas tecnicas ja eram ignoradas pelo
            \\" plano; aqui elas param de ser alcancaveis pelo cursor, e o que
            \\" escapar (:s, colagem) volta ao lugar assim que o texto muda.
            \\function! s:lstf_keep_cursor_in_name() abort
            \\  let l:line = getline('.')
            \\  " Linha nova (sem ID) e editavel inteira.
            \\  let l:id = matchstr(l:line, '^\/\d\+')
            \\  if empty(l:id) || !has_key(get(b:, 'lstf_prefix', {}), l:id) | return | endif
            \\  let l:start = s:lstf_name_start(l:line)
            \\  if l:start <= 0 | return | endif
            \\  if col('.') <= l:start | call cursor(line('.'), l:start + 1) | endif
            \\endfunction
            \\
            \\function! s:lstf_restore_columns() abort
            \\  if !exists('b:lstf_prefix') | return | endif
            \\  let l:line = getline('.')
            \\  let l:id = matchstr(l:line, '^\/\d\+')
            \\  if empty(l:id) || !has_key(b:lstf_prefix, l:id) | return | endif
            \\  let l:want = b:lstf_prefix[l:id]
            \\  if strpart(l:line, 0, len(l:want)) ==# l:want | return | endif
            \\  let l:start = s:lstf_name_start(l:line)
            \\  let l:name = l:start > 0 ? strpart(l:line, l:start) : ''
            \\  if empty(l:name)
            \\    let l:name = matchstr(l:line, '.*│\s*\S*\s*\zs.*')
            \\  endif
            \\  if empty(l:name) | let l:name = matchstr(l:line, '^\/\d\+\s\+\zs.*') | endif
            \\  let l:view = winsaveview()
            \\  silent! undojoin
            \\  call setline(line('.'), l:want . l:name)
            \\  call winrestview(l:view)
            \\endfunction
            \\
            \\function! s:lstf_capture_prefixes() abort
            \\  let b:lstf_prefix = {}
            \\  let b:lstf_original_path = {}
            \\  let b:lstf_id_width = 0
            \\  for l:line in getline(1, '$')
            \\    let l:id = matchstr(l:line, '^/\d\+')
            \\    if empty(l:id) | continue | endif
            \\    if b:lstf_id_width == 0
            \\      let b:lstf_id_width = matchend(l:line, '^/\d\+\s\+')
            \\    endif
            \\    let l:start = s:lstf_name_start(l:line)
            \\    if l:start > 0 | let b:lstf_prefix[l:id] = strpart(l:line, 0, l:start) | endif
            \\    let b:lstf_original_path[l:id] = s:lstf_entry_path(l:line)
            \\  endfor
            \\endfunction
            \\
            \\" Identifica destinos colidentes no buffer sem mutar o texto nem fazer
            \\" I/O de disco. Marca visualmente todas as linhas em conflito e exibe a
            \\" contagem na barra de status para feedback instantaneo enquanto o usuario edita.
            \\" Anotacao virtual: texto que aparece ao lado da linha sem estar no
            \\" buffer. E o que permite mostrar o desfecho previsto de uma colisao
            \\" sem que a previsao vire entrada do plano -- `getline()` nao a ve,
            \\" o `:w` nao a grava e ela nem marca o buffer como modificado. Quando
            \\" a previsao erra (arquivo oculto, outra janela colando ao mesmo
            \\" tempo), quem corrige e o preview da confirmacao, antes do disco.
            \\" Neovim usa extmark; Vim 9 usa text property com `text`. Piso mais
            \\" antigo fica so com o destaque colorido, como antes.
            \\" Detectado na primeira anotacao, nao na carga: `prop_type_add` exige
            \\" que o grupo de destaque ja exista, e as cores sao aplicadas depois
            \\" daqui. -1 e "ainda nao testado".
            \\let s:lstf_props = -1
            \\function! s:lstf_props_ok() abort
            \\  if s:lstf_props >= 0 | return s:lstf_props | endif
            \\  let s:lstf_props = 0
            \\  if !has('nvim') && exists('*prop_type_add')
            \\    try
            \\      if empty(prop_type_get('lstfPredict'))
            \\        call prop_type_add('lstfPredict', {'highlight': 'LstfPredict'})
            \\      endif
            \\      let s:lstf_props = 1
            \\    catch
            \\    endtry
            \\  endif
            \\  return s:lstf_props
            \\endfunction
            \\
            \\function! s:lstf_annotations_clear() abort
            \\  if has('nvim')
            \\    if exists('s:lstf_ns')
            \\      call nvim_buf_clear_namespace(0, s:lstf_ns, 0, -1)
            \\    endif
            \\  elseif s:lstf_props_ok()
            \\    silent! call prop_remove({'type': 'lstfPredict', 'all': 1})
            \\  endif
            \\endfunction
            \\
            \\function! s:lstf_annotate(lnum, text) abort
            \\  if has('nvim')
            \\    if !exists('s:lstf_ns')
            \\      let s:lstf_ns = nvim_create_namespace('lstf_predict')
            \\    endif
            \\    call nvim_buf_set_extmark(0, s:lstf_ns, a:lnum - 1, 0,
            \\      \ {'virt_text': [[a:text, 'LstfPredict']], 'virt_text_pos': 'eol'})
            \\  elseif s:lstf_props_ok()
            \\    " `text` em text property so existe a partir do Vim 9.0; em vez de
            \\    " cravar um numero de patch, desliga na primeira recusa.
            \\    try
            \\      call prop_add(a:lnum, 0, {'type': 'lstfPredict', 'text': a:text})
            \\    catch
            \\      let s:lstf_props = 0
            \\    endtry
            \\  endif
            \\endfunction
            \\
            \\" Mesma forma do sufixo que o lado Zig aplica (`plan.suffixed`):
            \\" radical e extensao do basename, diretorio preservado, barra final
            \\" para diretorio.
            \\function! s:lstf_suffixed(path, n) abort
            \\  let l:dir = a:path =~# '/$'
            \\  let l:body = l:dir ? substitute(a:path, '/\+$', '', '') : a:path
            \\  let l:slash = strridx(l:body, '/')
            \\  let l:head = l:slash >= 0 ? strpart(l:body, 0, l:slash + 1) : ''
            \\  let l:base = l:slash >= 0 ? strpart(l:body, l:slash + 1) : l:body
            \\  let l:dot = l:dir ? -1 : strridx(l:base, '.')
            \\  let l:stem = l:dot > 0 ? strpart(l:base, 0, l:dot) : l:base
            \\  let l:ext = l:dot > 0 ? strpart(l:base, l:dot) : ''
            \\  return printf('%s%s-%02d%s%s', l:head, l:stem, a:n, l:ext, l:dir ? '/' : '')
            \\endfunction
            \\
            \\" Um ID que nao e deste buffer veio colado de outra janela. Se a linha
            \\" dele ainda existe la, o gesto foi `yy` (copia, resolvida por sufixo);
            \\" se sumiu, foi `dd` (movimento, que recusa nome ocupado). Le os outros
            \\" buffers -- a mesma fonte que o laco consulta no `:w`, so que em
            \\" memoria: nao e um estado paralelo, e o mesmo estado lido aqui.
            \\function! s:lstf_id_ficou_na_origem(id, cache) abort
            \\  " Uma varredura por rodada, e so quando ha colisao com ID de fora:
            \\  " o `TextChanged` dispara a cada tecla e os outros buffers podem ser
            \\  " listagens grandes.
            \\  if !has_key(a:cache, 'ids')
            \\    let a:cache.ids = {}
            \\    for l:info in getbufinfo({'bufloaded': 1})
            \\      if l:info.bufnr == bufnr('%') | continue | endif
            \\      if l:info.name !~# '\.lstf$' | continue | endif
            \\      for l:linha in getbufline(l:info.bufnr, 1, '$')
            \\        let l:oid = matchstr(l:linha, '^/\d\+')
            \\        if !empty(l:oid) | let a:cache.ids[l:oid] = 1 | endif
            \\      endfor
            \\    endfor
            \\  endif
            \\  return has_key(a:cache.ids, a:id)
            \\endfunction
            \\
            \\function! s:lstf_update_collisions() abort
            \\  for l:match in get(w:, 'lstf_collision_matches', [])
            \\    silent! call matchdelete(l:match)
            \\  endfor
            \\  call s:lstf_annotations_clear()
            \\  let w:lstf_collision_matches = []
            \\  let b:lstf_collision_count = 0
            \\  let l:paths = {}
            \\  " Nomes ja ocupados por qualquer linha, para o sufixo previsto nao
            \\  " cair em cima de outro; IDs vistos, para saber qual linha e a
            \\  " primeira de um ID repetido (essa e a que fica).
            \\  let l:tomado = {}
            \\  let l:vistos = {}
            \\  let l:cache = {}
            \\  " IDs que vieram da listagem deste buffer. Um ID fora daqui e linha
            \\  " colada de outra janela.
            \\  let l:proprios = {}
            \\  for l:orig in get(b:, 'lstf_entry_lines', [])
            \\    let l:oid = matchstr(l:orig, '^/\d\+')
            \\    if !empty(l:oid) | let l:proprios[l:oid] = 1 | endif
            \\  endfor
            \\  let l:start = s:lstf_content_start()
            \\  if l:start <= 0 | redrawstatus | return | endif
            \\  for l:lnum in range(l:start, line('$'))
            \\    let l:line = getline(l:lnum)
            \\    let l:id = matchstr(l:line, '^/\d\+')
            \\    if !empty(l:id)
            \\      let l:path = s:lstf_entry_path(l:line)
            \\      let l:col = s:lstf_name_start(l:line) + 1
            \\    else
            \\      if l:line =~# '^\s*$' || l:line =~# '^[:#]' | continue | endif
            \\      let l:raw = substitute(l:line, '^\s*', '', '')
            \\      let l:arrow = match(l:raw, '\s->\s\|\s=>\s')
            \\      let l:path = l:arrow >= 0 ? substitute(strpart(l:raw, 0, l:arrow), '\s*$', '', '') : l:raw
            \\      let l:col = match(l:line, '\S') + 1
            \\    endif
            \\    if empty(l:path) || l:col <= 0 | continue | endif
            \\    let l:tomado[l:path] = 1
            \\    let l:primeiro = !has_key(l:vistos, l:id)
            \\    if !empty(l:id) | let l:vistos[l:id] = 1 | endif
            \\    if !has_key(l:paths, l:path) | let l:paths[l:path] = [] | endif
            \\    call add(l:paths[l:path], {'line': l:lnum, 'col': l:col, 'len': len(l:path),
            \\      \ 'id': l:id, 'primeiro': l:primeiro})
            \\  endfor
            \\  for l:path in keys(l:paths)
            \\    let l:uses = l:paths[l:path]
            \\    if len(l:uses) < 2 | continue | endif
            \\    let b:lstf_collision_count += len(l:uses)
            \\    for l:use in l:uses
            \\      call add(w:lstf_collision_matches,
            \\        \ matchaddpos('LstfCollision', [[l:use.line, l:use.col, l:use.len]], 20))
            \\      call s:lstf_prever(l:use, l:path, l:proprios, l:tomado, l:cache)
            \\    endfor
            \\  endfor
            \\  redrawstatus
            \\endfunction
            \\
            \\" O desfecho previsto de uma das linhas de uma colisao, anotado ao lado
            \\" dela. A linha que fica e a entrada da listagem: ID deste buffer, na
            \\" primeira aparicao. As outras sao destino, e e nelas que o desfecho
            \\" muda -- copia ganha sufixo, movimento e recusado, nome novo tambem.
            \\" Mesma regra que o lado Zig aplica; o que o helper nao enxerga (nome
            \\" ocupado por arquivo oculto, outra janela colando agora) tambem nao
            \\" acende o destaque, entao a anotacao nao promete mais do que ja se via.
            \\function! s:lstf_prever(use, path, proprios, tomado, cache) abort
            \\  if a:use.primeiro && !empty(a:use.id) && has_key(a:proprios, a:use.id)
            \\    return
            \\  endif
            \\  if empty(a:use.id)
            \\    call s:lstf_annotate(a:use.line, '  ✗ nome ja ocupado')
            \\    return
            \\  endif
            \\  if !has_key(a:proprios, a:use.id) && !s:lstf_id_ficou_na_origem(a:use.id, a:cache)
            \\    call s:lstf_annotate(a:use.line, '  ✗ ocupado: apague a linha dele ou renomeie')
            \\    return
            \\  endif
            \\  let l:n = 1
            \\  while l:n < 100
            \\    let l:cand = s:lstf_suffixed(a:path, l:n)
            \\    if !has_key(a:tomado, l:cand)
            \\      let a:tomado[l:cand] = 1
            \\      call s:lstf_annotate(a:use.line, '  → ' . l:cand)
            \\      return
            \\    endif
            \\    let l:n += 1
            \\  endwhile
            \\  call s:lstf_annotate(a:use.line, '  ✗ sem nome livre com sufixo')
            \\endfunction
            \\
            \\" Barra de topo: os titulos das colunas sao linha de tela, nao de
            \\" buffer. Nao rolam com a lista, nao dao para apagar e se redesenham
            \\" sozinhos quando o terminal muda de tamanho.
            \\" A barra e da tela inteira, mas descreve a janela da lista em foco:
            \\" a posicao fica guardada aqui e so e atualizada de dentro dela.
            \\function! s:lstf_follow_scroll() abort
            \\  " Qual janela de lista a moldura descreve quando o foco sai delas
            \\  " (popup de ajuda, janela de cabecalho): a ultima que esteve em
            \\  " foco, nao a primeira que a sessao abriu.
            \\  if exists('b:lstf_dir') | let s:lstf_list_win = win_getid() | endif
            \\  " A moldura e texto de buffer, entao nao se reajusta sozinha quando a
            \\  " largura muda. A janela de cabecalho tem a largura da tela inteira,
            \\  " acima de todas as janelas de lista: compara com `&columns`, nunca
            \\  " com a largura desta janela -- com um split elas sao diferentes por
            \\  " definicao, e a comparacao nunca fecharia (redesenho a cada tecla).
            \\  " A pasta entra na condicao porque a moldura segue o foco: sem ela,
            \\  " o Tab entre duas listas deixaria o caminho da outra na tela.
            \\  if s:lstf_frame && (&columns != get(s:, 'lstf_frame_width', -1)
            \\    \ || s:lstf_frame_location() !=# get(s:, 'lstf_frame_shown', ''))
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
            \\" Os titulos sao conteudo da linha 2 da janela de cabecalho (ver
            \\" `s:lstf_draw_frame`); a statusline desta janela virou a regra que
            \\" fecha a faixa por baixo -- linha propria, descolada do texto, e o
            \\" divisor `│` atravessa a regra para continuar nas entradas.
            \\function! LstfRuleBar() abort
            \\  if empty(s:lstf_titles) | return '' | endif
            \\  " Acompanha a rolagem horizontal da lista, senao as colunas sairiam
            \\  " do lugar assim que um nome longo empurrar a tela. O `leftcol`
            \\  " conta tambem os caracteres do ID, que estao no buffer mas
            \\  " ocultos por conceal e nao existem na barra.
            \\  let l:left = get(s:, 'lstf_leftcol', 0) - get(s:, 'lstf_id_width', 0)
            \\  let l:ruler = substitute(substitute(s:lstf_titles, '[^│]', '─', 'g'), '│', '┼', 'g')
            \\  let l:rest = strcharpart(l:ruler, max([0, l:left]))
            \\  " A faixa vai ate a borda da janela por conta propria: o
            \\  " preenchimento de `%=` sairia no grupo StatusLineNC, que e da
            \\  " barra de baixo tambem.
            \\  let l:win = exists('g:statusline_winid') ? win_id2win(g:statusline_winid) : 0
            \\  let l:pad = max([0, winwidth(l:win) - strdisplaywidth(l:rest)])
            \\  return '%#LstfFrame#' . l:rest . repeat('─', l:pad)
            \\endfunction
            \\
            \\" Linha de titulos como texto: devolve [linha, spans], onde spans sao
            \\" as posicoes em bytes de cada divisor `│` para o matchaddpos.
            \\function! s:lstf_titles_row(width) abort
            \\  if empty(s:lstf_titles) | return ['', []] | endif
            \\  let l:left = get(s:, 'lstf_leftcol', 0) - get(s:, 'lstf_id_width', 0)
            \\  let l:rest = strcharpart(s:lstf_titles, max([0, l:left]))
            \\  let l:out = ''
            \\  let l:bytes = 0
            \\  let l:spans = []
            \\  while 1
            \\    let l:i = match(l:rest, ' \=│ \=')
            \\    if l:i < 0 | break | endif
            \\    let l:seg = strpart(l:rest, 0, l:i)
            \\    let l:sep = matchstr(l:rest, ' \=│ \=')
            \\    call add(l:spans, [l:bytes + len(l:seg) + 1, len(l:sep)])
            \\    let l:out .= l:seg . l:sep
            \\    let l:bytes += len(l:seg) + len(l:sep)
            \\    let l:rest = strpart(l:rest, l:i + len(l:sep))
            \\  endwhile
            \\  let l:out .= l:rest
            \\  let l:pad = max([0, a:width - strdisplaywidth(l:out)])
            \\  return [l:out . repeat(' ', l:pad), l:spans]
            \\endfunction
            \\
            \\" Linha de moldura: caminho a esquerda, versao a direita, regua ligando
            \\" os dois -- a barra de titulo que o xpl-f desenha no topo da tela.
            \\" Volta em pedacos porque quem pinta e `matchaddpos`, por coluna de
            \\" byte: e conteudo de buffer, nao expressao de statusline.
            \\function! s:lstf_frame_parts(width, path) abort
            \\  let l:path = a:path
            \\  let l:avail = a:width - 10 - strdisplaywidth(s:lstf_identity)
            \\  if strdisplaywidth(l:path) > l:avail
            \\    let l:path = l:avail > 1 ? '…' . strcharpart(l:path, strchars(l:path) - l:avail + 1) : ''
            \\  endif
            \\  let l:fill = max([0, l:avail - strdisplaywidth(l:path)])
            \\  return ['╭─ ', ' ', l:path, ' ' . repeat('─', l:fill) . ' ', s:lstf_identity, ' ─╮']
            \\endfunction
            \\
            \\function! s:lstf_draw_frame() abort
            \\  if !exists('s:lstf_header_win') || win_id2win(s:lstf_header_win) == 0 | return | endif
            \\  let l:cur = win_getid()
            \\  let l:where = s:lstf_frame_location()
            \\  let s:lstf_frame_shown = l:where
            \\  noautocmd call win_gotoid(s:lstf_header_win)
            \\  let s:lstf_frame_width = winwidth(0)
            \\  let l:parts = s:lstf_frame_parts(s:lstf_frame_width, l:where)
            \\  let l:trow = s:lstf_titles_row(s:lstf_frame_width)
            \\  setlocal modifiable
            \\  call setline(1, [join(l:parts, ''), l:trow[0]])
            \\  setlocal nomodifiable nomodified
            \\  call clearmatches()
            \\  call matchaddpos('LstfFrame', [[1]], -5)
            \\  if !empty(l:trow[0])
            \\    call matchaddpos('LstfTitles', [[2]], -5)
            \\    for l:sp in l:trow[1]
            \\      call matchaddpos('LstfTitlesSep', [[2, l:sp[0], l:sp[1]]], -4)
            \\    endfor
            \\  endif
            \\  let l:icon_at = len(l:parts[0]) + 1
            \\  call matchaddpos('LstfIconDir', [[1, l:icon_at, len(l:parts[1])]], 10)
            \\  let l:spots = []
            \\  let l:at = l:icon_at + len(l:parts[1])
            \\  if len(l:parts[2]) > 0 | call add(l:spots, [1, l:at, len(l:parts[2])]) | endif
            \\  let l:at += len(l:parts[2]) + len(l:parts[3])
            \\  if len(l:parts[4]) > 0 | call add(l:spots, [1, l:at, len(l:parts[4])]) | endif
            \\  if !empty(l:spots) | call matchaddpos('LstfPath', l:spots, 10) | endif
            \\  noautocmd call win_gotoid(l:cur)
            \\endfunction
            \\
            \\" Janela de duas linhas no topo: moldura e titulos, que a
            \\" statusline dela fecha por baixo com a regra. Precisa ser
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
            \\  noautocmd topleft 2split __lstf_header__
            \\  let s:lstf_header_win = win_getid()
            \\  setlocal buftype=nofile bufhidden=wipe noswapfile nowrap
            \\  setlocal nonumber norelativenumber nocursorline winfixheight
            \\  setlocal signcolumn=no foldcolumn=0 colorcolumn=
            \\  setlocal statusline=%!LstfRuleBar()
            \\  augroup lstf_header
            \\    autocmd! * <buffer>
            \\    autocmd WinEnter <buffer> call s:lstf_leave_header()
            \\  augroup END
            \\  noautocmd call win_gotoid(s:lstf_list_win)
            \\  call s:lstf_draw_frame()
            \\endfunction
            \\
            \\" De qual janela a moldura fala. Com duas listas lado a lado o
            \\" cabecalho e um so, entao ele segue o foco; quando o foco esta fora
            \\" de uma lista (cabecalho, popup de ajuda), vale a ultima janela de
            \\" lista vista.
            \\function! s:lstf_frame_location() abort
            \\  if exists('b:lstf_location') && !empty(b:lstf_location)
            \\    return b:lstf_location
            \\  endif
            \\  if exists('s:lstf_list_win') && win_id2win(s:lstf_list_win) > 0
            \\    let l:loc = getbufvar(winbufnr(s:lstf_list_win), 'lstf_location')
            \\    if !empty(l:loc) | return l:loc | endif
            \\  endif
            \\  return empty($LST_F_LOCATION) ? getcwd() : $LST_F_LOCATION
            \\endfunction
            \\
            \\" O cursor nunca para no cabecalho: quem entrar volta para a lista.
            \\function! s:lstf_leave_header() abort
            \\  if winnr('$') > 1 | wincmd j | endif
            \\endfunction
            \\
            \\function! LstfStatusline() abort
            \\  let l:start = s:lstf_content_start()
            \\  let l:total = l:start > 0 ? len(filter(getline(l:start, '$'), 'v:val =~# ''^/\d\+\s\+''')) : 0
            \\  let l:current = l:start > 0 && line('.') >= l:start ? len(filter(getline(l:start, line('.')), 'v:val =~# ''^/\d\+\s\+''')) : 0
            \\  let l:mode = mode(1) =~# '^[iR]' ? 'EDIT' : mode(1) =~# '^[vV]' ? 'VISUAL' : 'NORMAL'
            \\  let l:name = substitute(s:lstf_entry_path(), '%', '%%', 'g')
            \\  let l:location = s:lstf_location()
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
            \\  let l:av = get(b:, 'lstf_notice', '')
            \\  let l:aviso = empty(l:av) ? '' : '%#LstfStatusNotice# ' . substitute(l:av, '%', '%%', 'g') . ' %#LstfStatusInfo#'
            \\  let l:collisions = get(b:, 'lstf_collision_count', 0)
            \\  let l:collision = l:collisions > 0 ? '%#LstfStatusCollision# colisao: ' . l:collisions . ' %#LstfStatusInfo#' : ''
            \\  return '%#LstfStatusMode# ' . l:mode . ' %#LstfStatusInfo# ' . l:current . '/' . l:total . ' ' . l:aviso . l:collision . ' %<' . l:where . '%=%#LstfStatusInfo# ' . l:tag . l:editor . ' %#LstfStatusHelp# F1=Help '
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
            \\" Dois diretorios lado a lado e mecanica pura do Vim: um `:vsplit`
            \\" desta mesma pasta e navegar numa das janelas. A que navegar troca
            \\" para o buffer da outra pasta; a outra continua onde estava. Nao ha
            \\" painel de categoria separada, nem renderizacao propria, nem tecla
            \\" silenciada: e uma janela com um buffer de diretorio, como qualquer
            \\" outra. Fechar e o de sempre (`:close`, `<C-w>c`).
            \\function! LstfSplit() abort
            \\  let l:onde = win_getid()
            \\  " `rightbelow`: a segunda janela abre a direita, como o usuario
            \\  " espera de um explorador. `noautocmd` porque o BufReadPost nao
            \\  " tem nada a montar aqui -- o buffer ja esta pronto.
            \\  noautocmd rightbelow vsplit
            \\  let l:nova = win_getid()
            \\  " O cabecalho ocupa o topo da tela inteira e as duas janelas de
            \\  " lista mudaram de largura sem o foco passar por nenhuma delas:
            \\  " a moldura so se reajusta se passarmos explicitamente.
            \\  call win_gotoid(l:onde)
            \\  call s:lstf_follow_scroll()
            \\  call s:lstf_draw_frame()
            \\  call win_gotoid(l:nova)
            \\  call s:lstf_follow_scroll()
            \\  call s:lstf_draw_frame()
            \\endfunction
            \\
            \\function! LstfRefresh() abort
            \\  let [l:err, l:out] = s:lstf_live('reload')
            \\  if l:err == 0
            \\    call s:lstf_show_buffer(l:out)
            \\    redraw
            \\    return
            \\  endif
            \\  silent! edit!
            \\  call s:lstf_after_reload()
            \\  let b:lstf_notice = 'Lista atualizada'
            \\  redrawstatus
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
            \\" Sem isto o Vim so enxerga o lado cterm e as cores em hex ficam
            \\" decorativas. O servidor, que nao anuncia truecolor, segue no cterm.
            \\if has('termguicolors') && !has('gui_running') && ($COLORTERM ==# 'truecolor' || $COLORTERM ==# '24bit')
            \\  set termguicolors
            \\endif
            \\function! s:lstf_apply_colors() abort
            \\  if &background ==# 'light'
            \\    highlight LstfStatusMode cterm=bold ctermfg=15 ctermbg=4 gui=bold guifg=#ffffff guibg=#1e66f5
            \\    highlight LstfStatusInfo ctermfg=0 ctermbg=NONE guifg=#4c4f69 guibg=NONE
            \\    highlight LstfStatusHelp cterm=bold ctermfg=15 ctermbg=4 gui=bold guifg=#ffffff guibg=#1e66f5
            \\    highlight LstfStatusNotice cterm=bold ctermfg=0 ctermbg=3 gui=bold guifg=#202020 guibg=#df8e1d
            \\    highlight LstfStatusCollision cterm=bold ctermfg=15 ctermbg=1 gui=bold guifg=#ffffff guibg=#d20f39
            \\    highlight LstfStatusSuggestion cterm=bold ctermfg=15 ctermbg=2 gui=bold guifg=#ffffff guibg=#40a02b
            \\    highlight LstfTitles cterm=bold ctermfg=0 ctermbg=254 gui=bold guifg=#4c4f69 guibg=#dce0e8
            \\    highlight LstfFrame ctermfg=246 guifg=#8c8fa1 guibg=NONE
            \\    highlight LstfPath cterm=bold ctermfg=166 gui=bold guifg=#bc5215 guibg=NONE
            \\    highlight LstfTitlesSep cterm=NONE ctermfg=248 ctermbg=254 gui=NONE guifg=#9ca0b0 guibg=#dce0e8
            \\    highlight LstfSep ctermfg=250 guifg=#bcc0cc guibg=NONE
            \\    highlight CursorLine cterm=NONE ctermbg=254 gui=NONE guibg=#ccd0da
            \\    highlight Visual cterm=NONE ctermbg=254 gui=NONE guibg=#ccd0da
            \\    highlight LstfVisualLine cterm=NONE ctermbg=254 gui=NONE guibg=#ccd0da
            \\    highlight LstfFile ctermfg=0 guifg=#4c4f69
            \\    highlight LstfLinkCreate ctermfg=6 gui=italic guifg=#179299
            \\    highlight LstfArrow cterm=bold ctermfg=6 gui=bold guifg=#179299
            \\    highlight LstfCollision cterm=bold,underline ctermfg=1 gui=bold,underline guifg=#d20f39
            \\    highlight LstfPredict cterm=italic ctermfg=1 gui=italic guifg=#d20f39
            \\    highlight LstfDateRecent cterm=NONE ctermfg=130 gui=NONE guifg=#df8e1d
            \\    highlight LstfDateDay cterm=NONE ctermfg=28 gui=NONE guifg=#40a02b
        );
        try w.writeAll(comptime explorer.vimIconHighlightsLight());
        try w.writeAll(
            \\  else
            \\    highlight LstfStatusMode cterm=bold ctermfg=0 ctermbg=12 gui=bold guifg=#1e1e2e guibg=#89b4fa
            \\    highlight LstfStatusInfo ctermfg=7 ctermbg=NONE guifg=#cdd6f4 guibg=NONE
            \\    highlight LstfStatusHelp cterm=bold ctermfg=0 ctermbg=12 gui=bold guifg=#1e1e2e guibg=#89b4fa
            \\    highlight LstfStatusNotice cterm=bold ctermfg=0 ctermbg=11 gui=bold guifg=#1e1e2e guibg=#f9e2af
            \\    highlight LstfStatusCollision cterm=bold ctermfg=15 ctermbg=1 gui=bold guifg=#ffffff guibg=#c94f6d
            \\    highlight LstfStatusSuggestion cterm=bold ctermfg=0 ctermbg=10 gui=bold guifg=#1e1e2e guibg=#a6e3a1
            \\    highlight LstfTitles cterm=bold ctermfg=15 ctermbg=236 gui=bold guifg=#cdd6f4 guibg=#2a2b3c
            \\    highlight LstfFrame ctermfg=245 guifg=#6c7086 guibg=NONE
            \\    highlight LstfPath cterm=bold ctermfg=208 gui=bold guifg=#fab387 guibg=NONE
            \\    highlight LstfTitlesSep cterm=NONE ctermfg=245 ctermbg=236 gui=NONE guifg=#6c7086 guibg=#2a2b3c
            \\    highlight LstfSep ctermfg=245 guifg=#6c7086 guibg=NONE
            \\    highlight CursorLine cterm=NONE ctermbg=240 gui=NONE guibg=#45475a
            \\    highlight Visual cterm=NONE ctermbg=240 gui=NONE guibg=#45475a
            \\    highlight LstfVisualLine cterm=NONE ctermbg=240 gui=NONE guibg=#45475a
            \\    highlight LstfFile ctermfg=252 guifg=#c0caf5
            \\    highlight LstfLinkCreate ctermfg=14 gui=italic guifg=#56b6c2
            \\    highlight LstfArrow cterm=bold ctermfg=14 gui=bold guifg=#56b6c2
            \\    highlight LstfCollision cterm=bold,underline ctermfg=9 gui=bold,underline guifg=#f38ba8
            \\    highlight LstfPredict cterm=italic ctermfg=9 gui=italic guifg=#f38ba8
            \\    highlight LstfDateRecent cterm=NONE ctermfg=11 gui=NONE guifg=#f9e2af
            \\    highlight LstfDateDay cterm=NONE ctermfg=10 gui=NONE guifg=#a6d189
        );
        try w.writeAll(comptime explorer.vimIconHighlightsDark());
        try w.writeAll(
            \\  endif
            \\  if exists('s:lstf_header_win') && win_id2win(s:lstf_header_win) > 0
            \\    call s:lstf_draw_frame()
            \\  endif
            \\endfunction
            \\call s:lstf_apply_colors()
            \\augroup lstf_colors
            \\  autocmd!
            \\  autocmd OptionSet background call s:lstf_apply_colors()
            \\augroup END
            \\set laststatus=2
            \\set noshowmode showtabline=0
            \\set shortmess+=F
            \\set noruler noshowcmd
            \\
            \\sign define LstfVisualLineSign linehl=LstfVisualLine
            \\function! s:lstf_clear_visual_lines() abort
            \\  execute 'sign unplace * group=lstf_visual buffer=' . bufnr('%')
            \\endfunction
            \\
            \\function! s:lstf_highlight_visual_lines() abort
            \\  call s:lstf_clear_visual_lines()
            \\  let l:mode = mode()
            \\  if l:mode !=# 'v' && l:mode !=# 'V' && l:mode !=# "\\<C-V>"
            \\    return
            \\  endif
            \\  let l:first = min([line('.'), line('v')])
            \\  let l:last = max([line('.'), line('v')])
            \\  for l:lnum in range(l:first, l:last)
            \\    execute 'sign place ' . l:lnum . ' group=lstf_visual line=' . l:lnum . ' name=LstfVisualLineSign buffer=' . bufnr('%')
            \\  endfor
            \\endfunction
            \\
            \\" `:edit!` preserva opcoes e mapeamentos locais, mas Vim e Neovim
            \\" apagam os grupos de sintaxe do buffer relido. Centralizar toda a
            \\" aparencia local aqui deixa a abertura e cada recarga identicas.
            \\function! s:lstf_configure_buffer() abort
            \\  call s:lstf_clear_visual_lines()
            \\  setlocal statusline=%!LstfStatusline()
            \\  if exists('+fillchars')
            \\    execute "setlocal fillchars+=eob:\\ "
            \\  endif
            \\  setlocal nonumber norelativenumber nowrap sidescrolloff=8 cursorline cursorlineopt=line
            \\  setlocal signcolumn=no foldcolumn=0 colorcolumn=
            \\  setlocal conceallevel=2 concealcursor=nvic
            \\  silent! syntax clear LstfInternalId LstfSep LstfFile LstfLinkCreate LstfArrow LstfDateRecent LstfDateDay
            \\  syntax match LstfInternalId /^\/\d\+\s\+/ conceal
            \\  syntax match LstfSep /│/ contained
            \\  syntax match LstfArrow / -> \| => / contained
            \\  syntax match LstfLinkCreate /^[^\/:\#].*\%( -> \| => \).*$/ contains=LstfArrow
            \\  " O sequencial e metadado interno: oculta-lo tambem na linha do
            \\  " cursor evita deslocar as colunas, inclusive ao voltar do :find.
            \\  " A linha inteira e um item, com o ID e os divisores contidos
            \\  " nela -- e neutra por design: o tipo se ve no icone colorido,
            \\  " pintado pelas regras geradas da tabela Zig logo abaixo. Ancorar
            \\  " nos cinco divisores, e nao em contagem de caracteres, e o que
            \\  " deixa o nome com `│` dentro ainda cair no grupo certo.
            \\  syntax match LstfFile /^\/\d\+\s\+[-dl?]\%( │ [^│]*\)\{3,4} │ .*$/ contains=LstfInternalId,LstfSep
        );
        try w.writeAll(comptime explorer.vimIconSyntax());
        try w.writeAll(
            \\  " Destaque de data para recentes e hoje (arquivos antigos usam a cor padrao da linha):
            \\  let l:all = 'LstfFile'
            \\  let l:now = localtime()
            \\  let l:today = strftime('%Y-%m-%d', l:now)
            \\  let l:cur_hour = strftime('%Y-%m-%d %H:', l:now)
            \\  let l:prev_hour = strftime('%Y-%m-%d %H:', l:now - 3600)
            \\  execute 'syntax match LstfDateDay /' . l:today . ' \d\{2}:\d\{2}/ containedin=' . l:all
            \\  execute 'syntax match LstfDateRecent /' . l:cur_hour . '\d\{2}/ containedin=' . l:all
            \\  execute 'syntax match LstfDateRecent /' . l:prev_hour . '\d\{2}/ containedin=' . l:all
            \\endfunction
            \\" Autocmds locais de um buffer de listagem. `autocmd! * <buffer>`
            \\" limpa so os deste buffer, entao chamar de novo em cada buffer
            \\" aberto e seguro -- e necessario, porque `:edit!` de um arquivo
            \\" novo nao herda nada do anterior.
            \\function! s:lstf_buffer_autocmds() abort
            \\  call s:lstf_configure_buffer()
            \\  augroup lstf_buffer
            \\    autocmd! * <buffer>
            \\    autocmd BufWritePre <buffer> call s:lstf_prepare_save()
            \\    autocmd TextChanged <buffer> call s:lstf_restore_header()
            \\    autocmd CursorMoved <buffer> call s:lstf_keep_cursor_below_header()
            \\    autocmd CursorMoved,CursorMovedI <buffer> call s:lstf_keep_cursor_in_name()
            \\    autocmd CursorMoved,CursorMovedI <buffer> call s:lstf_follow_scroll()
            \\    autocmd CursorMoved <buffer> call s:lstf_highlight_visual_lines()
            \\    autocmd WinEnter,BufEnter,VimResized <buffer> call s:lstf_follow_scroll()
            \\    autocmd TextChanged,InsertLeave <buffer> call s:lstf_restore_columns()
            \\    autocmd InsertLeave <buffer> call s:lstf_restore_header()
            \\    autocmd TextChanged,InsertLeave <buffer> call s:lstf_update_collisions()
            \\    " Salvar alteracoes comuns aplica pela sessao viva; diretivas e o
            \\    " fallback fecham todas as janelas da instancia controlada.
            \\    autocmd BufWritePost <buffer> call s:lstf_after_save()
            \\  augroup END
            \\endfunction
            \\augroup lstf_statusline
            \\  autocmd!
            \\  autocmd ModeChanged * redrawstatus | if exists('b:lstf_header') | call s:lstf_highlight_visual_lines() | endif
            \\  " Abrir ou fechar um split estreita a janela da lista sem passar por
            \\  " ela: sem isto a barra de topo so voltaria a sincronizar no proximo
            \\  " Tab. Vim antigo nao tem o evento; ai sincroniza no Tab.
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
            \\  call s:lstf_configure_buffer()
            \\  if filereadable($LST_F_STATE . '/theme')
            \\    let l:saved_bg = get(readfile($LST_F_STATE . '/theme'), 0, '')
            \\    if !empty(l:saved_bg) && l:saved_bg !=# &background
            \\      let &background = l:saved_bg
            \\      call s:lstf_apply_colors()
            \\    endif
            \\  endif
            \\  " Estado deste buffer, lido dos sidecars que o pai gravou ao lado do
            \\  " arquivo de conteudo. Por buffer, e nao do estado global: com duas
            \\  " janelas abertas o "corrente" do pai e o de quem pediu por ultimo,
            \\  " que nao e necessariamente esta janela.
            \\  let l:side_dir = s:lstf_sidecar('.dir')
            \\  if !empty(l:side_dir)
            \\    let b:lstf_dir = get(readfile(l:side_dir), 0, '')
            \\  elseif filereadable($LST_F_STATE . '/base')
            \\    let b:lstf_dir = get(readfile($LST_F_STATE . '/base'), 0, '')
            \\  endif
            \\  if exists('b:lstf_dir') && !empty(b:lstf_dir)
            \\    " `lcd`, nao `cd`: o cwd e da janela, para que `gf` e a completude
            \\    " de `:e` sigam valendo por pasta em cada uma das duas janelas.
            \\    silent! execute 'lcd ' . fnameescape(b:lstf_dir)
            \\  endif
            \\  let l:side_loc = s:lstf_sidecar('.location')
            \\  if !empty(l:side_loc)
            \\    let b:lstf_location = get(readfile(l:side_loc), 0, '')
            \\  elseif filereadable($LST_F_STATE . '/location')
            \\    let b:lstf_location = get(readfile($LST_F_STATE . '/location'), 0, '')
            \\  endif
            \\  let l:side_hdr = s:lstf_sidecar('.header')
            \\  if empty(l:side_hdr) && filereadable($LST_F_STATE . '/header')
            \\    let l:side_hdr = $LST_F_STATE . '/header'
            \\  endif
            \\  if !empty(l:side_hdr)
            \\    let b:lstf_header = readfile(l:side_hdr)
            \\    call s:lstf_restore_header()
            \\    " Cabecalho ocupando o buffer todo: sem uma linha abaixo dele nao
            \\    " havia onde pousar o cursor para digitar o primeiro nome.
            \\    if line('$') <= len(b:lstf_header) | call append('$', '') | endif
            \\    setlocal nomodified
            \\  endif
            \\  " O aviso e do buffer, nao da sessao: com duas janelas abertas o
            \\  " arquivo global e o de quem pediu por ultimo, e o recado de uma
            \\  " apareceria na barra da outra. O sidecar vem ao lado do conteudo.
            \\  let l:side_note = s:lstf_sidecar('.notice')
            \\  if !empty(l:side_note)
            \\    let b:lstf_notice = get(readfile(l:side_note), 0, '')
            \\  else
            \\    let b:lstf_notice = filereadable($LST_F_STATE . '/notice')
            \\      \ ? get(readfile($LST_F_STATE . '/notice'), 0, '') : ''
            \\  endif
            \\  call s:lstf_capture_prefixes()
            \\  call s:lstf_update_collisions()
            \\  let b:lstf_entry_lines = s:lstf_entry_lines()
            \\  call s:lstf_follow_scroll()
            \\  call s:lstf_restore_cursor()
            \\  call s:lstf_draw_frame()
            \\  setlocal nomodified
            \\  redrawstatus!
            \\endfunction
            \\
            \\" A ajuda pode manter o foco em um popup ou painel auxiliar. Como
            \\" esta instancia do Vim e exclusiva do lst-f, F1 e F2 sao globais
            \\" para nunca deixar o Vim abrir :help em um split e alterar a tela.
            \\nnoremap <silent> <F1> :call LstfHelp()<CR>
            \\nnoremap <silent> <F2> :call LstfToggleTheme()<CR>
            \\
            \\" Tudo que e local a um buffer de listagem: opcoes, sintaxe,
            \\" autocmds, mapas, comandos e abreviaturas. Uma funcao so, chamada
            \\" na abertura e a cada buffer novo que o Vim ler -- e o que faz
            \\" `:vsplit` + navegar abrir outro diretorio com as mesmas teclas,
            \\" sem um "painel de destino" de categoria separada.
            \\" Expansao de `:` no cmdline: transforma o que o usuario digitou no
            \\" comando-local correspondente. Global porque o cmdline nao e
            \\" do buffer; as funcoes abaixo idem, e por isso vivem fora de
            \\" s:lstf_setup_buffer() -- Vim nao aceita definicao aninhada.
            \\
            \\function! s:lstf_cmd_cr() abort
            \\  if getcmdtype() ==# ':'
            \\    let l:cmd = substitute(getcmdline(), '^\s*', '', '')
            \\    if l:cmd =~# '^cd\%(\s.*\|\)$'
            \\      return "\x15Cd" . l:cmd[2:] . "\r"
            \\    elseif l:cmd =~# '^home$'
            \\      return "\x15Home\r"
            \\    elseif l:cmd =~# '^back$'
            \\      return "\x15Back\r"
            \\    elseif l:cmd =~# '^forward$'
            \\      return "\x15Forward\r"
            \\    elseif l:cmd =~# '^hidden$'
            \\      return "\x15Hidden\r"
            \\    elseif l:cmd =~# '^theme\%(\s.*\|\)$'
            \\      return "\x15Theme" . l:cmd[5:] . "\r"
            \\    elseif l:cmd ==# 'light'
            \\      return "\x15Light\r"
            \\    elseif l:cmd ==# 'dark'
            \\      return "\x15Dark\r"
            \\    elseif l:cmd =~# '^find\%(\s.*\|\)$'
            \\      return "\x15Find" . l:cmd[4:] . "\r"
            \\    elseif l:cmd =~# '^\%(sh\|shell\|terminal\|term\)\%(\s.*\|\)$'
            \\      return "\x15Sh" . l:cmd[match(l:cmd, '\s\|\$')..] . "\r"
            \\    elseif l:cmd =~# '^\%(ln\|link\|symlink\)\%(\s.*\|\)$'
            \\      return "\x15Ln" . l:cmd[match(l:cmd, '\s\|\$')..] . "\r"
            \\    elseif l:cmd =~# '^hardlink\%(\s.*\|\)$'
            \\      return "\x15Hardlink" . l:cmd[8:] . "\r"
            \\    elseif l:cmd =~# '^\%(yank\|copy\|relpath\)\%(\s.*\|\)$'
            \\      return "\x15Yank\r"
            \\    elseif l:cmd =~# '^\%(abspath\|realpath\)\%(\s.*\|\)$'
            \\      return "\x15YankAbs\r"
            \\    elseif l:cmd ==# 'q' || l:cmd ==# 'quit'
            \\      return "\x15call LstfQuit()\r"
            \\    endif
            \\  endif
            \\  return "\r"
            \\endfunction
            \\cnoremap <expr> <CR> <SID>lstf_cmd_cr()
            \\
            \\function! s:lstf_cmd_ln(args) abort
            \\  if empty(a:args) | return | endif
            \\  call s:lstf_write_directive(':ln ' . a:args)
            \\endfunction
            \\function! s:lstf_cmd_hardlink(args) abort
            \\  if empty(a:args) | return | endif
            \\  call s:lstf_write_directive(':hardlink ' . a:args)
            \\endfunction
            \\
            \\function! s:lstf_setup_buffer() abort
            \\  call s:lstf_buffer_autocmds()
            \\  " A ajuda pode manter o foco em um popup ou painel auxiliar. Como esta
            \\  " instancia do Vim e exclusiva do lst-f, F1 e global para nunca deixar
            \\  " o Vim abrir :help em um split e alterar a tela controlada.
            \\  nnoremap <buffer> <silent> ? :call LstfHelp()<CR>
            \\  nnoremap <buffer> <silent> cob :call LstfToggleTheme()<CR>
            \\  nnoremap <buffer> <silent> <CR> :call LstfOpen()<CR>
            \\  nnoremap <buffer> <silent> . :call LstfToggleHidden()<CR>
            \\  nnoremap <buffer> <silent> - :call LstfUp()<CR>
            \\  nnoremap <buffer> <silent> ~ :call LstfHome()<CR>
            \\  nnoremap <buffer> <silent> gh :call LstfHome()<CR>
            \\  nnoremap <buffer> <silent> <lt> :call LstfBack()<CR>
            \\  nnoremap <buffer> <silent> > :call LstfForward()<CR>
            \\  nnoremap <buffer> <silent> <Bslash> :call LstfTree()<CR>
            \\  nnoremap <buffer> <silent> <F4> :call LstfShell()<CR>
            \\  nnoremap <buffer> <silent> <C-p> :call LstfFind()<CR>
            \\  nnoremap <buffer> <silent> <C-a> ggVG
            \\  nnoremap <buffer> <silent> r :call LstfRefresh()<CR>
            \\  nnoremap <buffer> <silent> <C-r> :call LstfRefresh()<CR>
            \\  nnoremap <buffer> <silent> <C-s> :call LstfSplit()<CR>
            \\  nnoremap <buffer> <silent> <Tab> :<C-u>wincmd w<CR>
            \\  nnoremap <buffer> <silent> yr :call LstfYank(0)<CR>
            \\  nnoremap <buffer> <silent> yp :call LstfYank(0)<CR>
            \\  nnoremap <buffer> <silent> ya :call LstfYank(1)<CR>
            \\  nnoremap <buffer> <silent> yA :call LstfYank(1)<CR>
            \\  xnoremap <buffer> <silent> yr :<C-u>call <SID>lstf_yank_visual(0)<CR>
            \\  xnoremap <buffer> <silent> yp :<C-u>call <SID>lstf_yank_visual(0)<CR>
            \\  xnoremap <buffer> <silent> ya :<C-u>call <SID>lstf_yank_visual(1)<CR>
            \\  xnoremap <buffer> <silent> yA :<C-u>call <SID>lstf_yank_visual(1)<CR>
            \\  nnoremap <buffer> <silent> q :call LstfQuit()<CR>
            \\  nnoremap <buffer> <silent> ZZ :call LstfQuit()<CR>
            \\  command! -buffer -nargs=? -complete=dir Cd call LstfCd(<q-args>)
            \\  command! -buffer -nargs=? -complete=dir CD call LstfCd(<q-args>)
            \\  cnoreabbrev <expr> <buffer> cd getcmdtype() ==# ':' && getcmdline() =~# '^cd\%(\s.*\|\)$' ? 'Cd' : 'cd'
            \\  command! -buffer -nargs=0 Home call LstfHome()
            \\  cnoreabbrev <expr> <buffer> home getcmdtype() ==# ':' && getcmdline() ==# 'home' ? 'call LstfHome()' : 'home'
            \\  command! -buffer -nargs=0 Back call LstfBack()
            \\  cnoreabbrev <expr> <buffer> back getcmdtype() ==# ':' && getcmdline() ==# 'back' ? 'Back' : 'back'
            \\  command! -buffer -nargs=0 Forward call LstfForward()
            \\  cnoreabbrev <expr> <buffer> forward getcmdtype() ==# ':' && getcmdline() ==# 'forward' ? 'Forward' : 'forward'
            \\  command! -buffer -nargs=0 Hidden call LstfToggleHidden()
            \\  cnoreabbrev <expr> <buffer> hidden getcmdtype() ==# ':' && getcmdline() ==# 'hidden' ? 'Hidden' : 'hidden'
            \\  command! -buffer -nargs=? Theme call LstfToggleTheme(<q-args>)
            \\  command! -buffer -nargs=0 Light call LstfToggleTheme('light')
            \\  command! -buffer -nargs=0 Dark call LstfToggleTheme('dark')
            \\  cnoreabbrev <expr> <buffer> theme getcmdtype() ==# ':' && getcmdline() =~# '^theme\%(\s.*\|\)$' ? 'Theme' : 'theme'
            \\  cnoreabbrev <expr> <buffer> light getcmdtype() ==# ':' && getcmdline() ==# 'light' ? 'Light' : 'light'
            \\  cnoreabbrev <expr> <buffer> dark getcmdtype() ==# ':' && getcmdline() ==# 'dark' ? 'Dark' : 'dark'
            \\  command! -buffer -nargs=? Find call s:lstf_cmd_find(<q-args>)
            \\  cnoreabbrev <expr> <buffer> find getcmdtype() ==# ':' && getcmdline() =~# '^find\%(\s.*\|\)$' ? 'Find' : 'find'
            \\  command! -buffer -nargs=? Sh call LstfShell(<q-args>)
            \\  command! -buffer -nargs=? Shell call LstfShell(<q-args>)
            \\  command! -buffer -nargs=? Terminal call LstfShell(<q-args>)
            \\  command! -buffer -nargs=? Term call LstfShell(<q-args>)
            \\  cnoreabbrev <expr> <buffer> sh getcmdtype() ==# ':' && getcmdline() =~# '^sh\%(\s.*\|\)$' ? 'Sh' : 'sh'
            \\  cnoreabbrev <expr> <buffer> shell getcmdtype() ==# ':' && getcmdline() =~# '^shell\%(\s.*\|\)$' ? 'Shell' : 'shell'
            \\  cnoreabbrev <expr> <buffer> terminal getcmdtype() ==# ':' && getcmdline() =~# '^terminal\%(\s.*\|\)$' ? 'Terminal' : 'terminal'
            \\  cnoreabbrev <expr> <buffer> term getcmdtype() ==# ':' && getcmdline() =~# '^term\%(\s.*\|\)$' ? 'Term' : 'term'
            \\  command! -buffer -nargs=0 Yank call LstfYank(0)
            \\  command! -buffer -nargs=0 YankRel call LstfYank(0)
            \\  command! -buffer -nargs=0 YankAbs call LstfYank(1)
            \\  command! -buffer -nargs=0 Copy call LstfYank(0)
            \\  cnoreabbrev <expr> <buffer> yank getcmdtype() ==# ':' && getcmdline() =~# '^yank\%(\s.*\|\)$' ? 'Yank' : 'yank'
            \\  cnoreabbrev <expr> <buffer> copy getcmdtype() ==# ':' && getcmdline() =~# '^copy\%(\s.*\|\)$' ? 'Copy' : 'copy'
            \\  cnoreabbrev <expr> <buffer> relpath getcmdtype() ==# ':' && getcmdline() =~# '^relpath\%(\s.*\|\)$' ? 'Yank' : 'relpath'
            \\  cnoreabbrev <expr> <buffer> abspath getcmdtype() ==# ':' && getcmdline() =~# '^abspath\%(\s.*\|\)$' ? 'YankAbs' : 'abspath'
            \\  cnoreabbrev <expr> <buffer> realpath getcmdtype() ==# ':' && getcmdline() =~# '^realpath\%(\s.*\|\)$' ? 'YankAbs' : 'realpath'
            \\  command! -buffer -nargs=+ Ln call s:lstf_cmd_ln(<q-args>)
            \\  command! -buffer -nargs=+ Link call s:lstf_cmd_ln(<q-args>)
            \\  command! -buffer -nargs=+ Symlink call s:lstf_cmd_ln(<q-args>)
            \\  command! -buffer -nargs=+ Hardlink call s:lstf_cmd_hardlink(<q-args>)
            \\  cnoreabbrev <expr> <buffer> ln getcmdtype() ==# ':' && getcmdline() =~# '^ln\%(\s.*\|\)$' ? 'Ln' : 'ln'
            \\  cnoreabbrev <expr> <buffer> link getcmdtype() ==# ':' && getcmdline() =~# '^link\%(\s.*\|\)$' ? 'Link' : 'link'
            \\  cnoreabbrev <expr> <buffer> symlink getcmdtype() ==# ':' && getcmdline() =~# '^symlink\%(\s.*\|\)$' ? 'Symlink' : 'symlink'
            \\  cnoreabbrev <expr> <buffer> hardlink getcmdtype() ==# ':' && getcmdline() =~# '^hardlink\%(\s.*\|\)$' ? 'Hardlink' : 'hardlink'
            \\  cnoreabbrev <expr> <buffer> q getcmdtype() ==# ':' && getcmdline() ==# 'q' ? 'call LstfQuit()' : 'q'
            \\  cnoreabbrev <expr> <buffer> quit getcmdtype() ==# ':' && getcmdline() ==# 'quit' ? 'call LstfQuit()' : 'quit'
            \\endfunction
            \\
            \\" Buffer de listagem que o Vim ler recebe o tratamento acima. O
            \\" arquivo inicial e lido antes do `-S`, entao este autocmd pega so
            \\" os seguintes: os que a navegacao viva abre ao trocar de pasta.
            \\function! s:lstf_open_buffer() abort
            \\  call s:lstf_setup_buffer()
            \\  call s:lstf_after_reload()
            \\endfunction
            \\
            \\augroup lstf_buffers
            \\  autocmd!
            \\  autocmd BufReadPost *.lstf let s:lstf_opened = 1 | call s:lstf_open_buffer()
            \\augroup END
            \\
            \\let s:lstf_opened = 0
            \\call s:lstf_open_buffer()
            \\" Por ultimo: abrir o cabecalho antes daqui faria os `setlocal` e os
            \\" mapeamentos `<buffer>` acima cairem no buffer errado, porque o
            \\" buffer corrente passaria a ser o da janela de topo.
            \\call s:lstf_open_header()
            \\redrawstatus | echo ''
            \\
        );
        try w.flush();
    }
};
