const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const session = @import("lst_f").session;
const History = session.History;

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

test "writeHelperScript inclui grupos de highlight e syntax de data por antiguidade" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state: session.State = .{
        .dir = tmp.dir,
        .path = "/tmp/test",
    };
    try state.writeHelperScript(io, "lst-f", "test");
    const script = try tmp.dir.readFileAlloc(io, "helper.vim", arena, .limited(1024 * 1024));

    try testing.expect(std.mem.indexOf(u8, script, "LstfDateRecent") != null);
    try testing.expect(std.mem.indexOf(u8, script, "LstfDateDay") != null);
    try testing.expect(std.mem.indexOf(u8, script, "LstfDateOld") == null);
    try testing.expect(std.mem.indexOf(u8, script, "syntax match LstfDateRecent") != null);
    try testing.expect(std.mem.indexOf(u8, script, "syntax match LstfDateDay") != null);

    // Deteccao dinamica de tema claro e escuro no Vim/Neovim
    try testing.expect(std.mem.indexOf(u8, script, "function! s:lstf_apply_colors()") != null);
    try testing.expect(std.mem.indexOf(u8, script, "if &background ==# 'light'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "autocmd OptionSet background call s:lstf_apply_colors()") != null);
    try testing.expect(std.mem.indexOf(u8, script, "guifg=#4c4f69") != null); // Cor de texto clara (Latte)
    try testing.expect(std.mem.indexOf(u8, script, "guibg=#ccd0da") != null); // Cursorline claro (Latte)
    try testing.expect(std.mem.indexOf(u8, script, "guifg=#c0caf5") != null); // Cor de texto escura (Mocha)

    // Toggle interno de tema (F2, cob, :theme, :light, :dark)
    try testing.expect(std.mem.indexOf(u8, script, "function! LstfToggleTheme(...)") != null);
    try testing.expect(std.mem.indexOf(u8, script, "nnoremap <silent> <F2> :call LstfToggleTheme()<CR>") != null);
    try testing.expect(std.mem.indexOf(u8, script, "nnoremap <buffer> <silent> cob :call LstfToggleTheme()<CR>") != null);
    try testing.expect(std.mem.indexOf(u8, script, "command! -buffer -nargs=? Theme call LstfToggleTheme(<q-args>)") != null);
    try testing.expect(std.mem.indexOf(u8, script, "command! -buffer -nargs=0 Light call LstfToggleTheme('light')") != null);
    try testing.expect(std.mem.indexOf(u8, script, "command! -buffer -nargs=0 Dark call LstfToggleTheme('dark')") != null);

    // Dois diretorios lado a lado sao mecanica pura do Vim: `:vsplit` da mesma
    // pasta e navegar numa das janelas. O "painel de destino" de categoria
    // separada (render, parser e keymap proprios) nao existe mais.
    try testing.expect(std.mem.indexOf(u8, script, "function! LstfSplit() abort") != null);
    try testing.expect(std.mem.indexOf(u8, script, "nnoremap <buffer> <silent> <C-s> :call LstfSplit()<CR>") != null);
    try testing.expect(std.mem.indexOf(u8, script, "__lstf_dest_panel__") == null);
    try testing.expect(std.mem.indexOf(u8, script, "lstf_dest_paste") == null);
    try testing.expect(std.mem.indexOf(u8, script, "LstfToggleSplit") == null);

    // Sem painel, nao ha buffer de lista trancado: `u`/`U` silenciados e
    // `undolevels=-1` eram remendos para o E21 que ele provocava.
    try testing.expect(std.mem.indexOf(u8, script, "<Nop>") == null);
    try testing.expect(std.mem.indexOf(u8, script, "undolevels=-1") == null);

    // Cada buffer de diretorio e montado de novo ao ser lido, senao o que a
    // navegacao abre nao teria tecla nenhuma.
    try testing.expect(std.mem.indexOf(u8, script, "function! s:lstf_setup_buffer() abort") != null);
    try testing.expect(std.mem.indexOf(u8, script, "autocmd BufReadPost *.lstf let s:lstf_opened = 1 | call s:lstf_open_buffer()") != null);

    // Ancora unica: o diretorio do proprio buffer, nao um estado global.
    try testing.expect(std.mem.indexOf(u8, script, "function! s:lstf_dir() abort") != null);
    try testing.expect(std.mem.indexOf(u8, script, "b:lstf_dir") != null);
}
