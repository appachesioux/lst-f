" Run after: zig build dump-helper > /tmp/lstf-helper.vim
" vim -Nu NONE -i NONE -n -es -S test/sort_test.vim
" nvim --headless -u NONE -i NONE -n -S test/sort_test.vim
set nomore
let s:root = tempname()
call mkdir(s:root, 'p')
let $LST_F_STATE = s:root
let s:large = '/0001  f │ rw-r--r-- │ owner    │      1.0K │ date │ x  zebra'
let s:small = '/0002  f │ rw-r--r-- │ owner    │      900B │ date │ x  alpha'
let s:close = '/0003  f │ rw-r--r-- │ owner    │      1.0K │ date │ x  beta'
let s:dir = '/0004  d │ rwxr-xr-x │ owner    │         - │ date │ x  folder/'
call writefile([repeat('x', 1050)], s:root . '/zebra', 'b')
call writefile([repeat('x', 900)], s:root . '/alpha', 'b')
call writefile([repeat('x', 1040)], s:root . '/beta', 'b')
call mkdir(s:root . '/folder')
call writefile([s:root], s:root . '/base')
call setline(1, [s:large, s:small, s:close, s:dir])
setlocal nomodified
source /tmp/lstf-helper.vim

" Exercise the real command-line mapping, not just the implementation.
call feedkeys(":sort\<CR>", 'xt')
call assert_equal([s:dir, s:small, s:close, s:large], getline(1, '$'))
call assert_false(&modified)
call feedkeys(":sort!\<CR>", 'xt')
call assert_equal([s:dir, s:large, s:close, s:small], getline(1, '$'))
call feedkeys(":sort size\<CR>", 'xt')
call assert_equal([s:dir, s:small, s:close, s:large], getline(1, '$'))
call feedkeys(":sort! size\<CR>", 'xt')
call assert_equal([s:dir, s:large, s:close, s:small], getline(1, '$'))

" Rename pending: use the original file for exact size, preserve the full line.
let s:renamed = substitute(s:large, 'zebra$', 'aardvark', '')
call setline(2, s:renamed)
call feedkeys(":sort size\<CR>", 'xt')
call assert_equal([s:dir, s:small, s:close, s:renamed], getline(1, '$'))
call assert_true(&modified)
call feedkeys(":sort\<CR>", 'xt')
call assert_equal([s:dir, s:renamed, s:small, s:close], getline(1, '$'))

" Explicit/visual ranges leave all other lines alone.
call feedkeys(":3,4sort! name\<CR>", 'xt')
call assert_equal([s:dir, s:renamed, s:close, s:small], getline(1, '$'))
call cursor(3, 1)
call feedkeys("Vj:sort\<CR>", 'xt')
call assert_equal([s:dir, s:renamed, s:small, s:close], getline(1, '$'))

" New entries and directives remain intact; names need no on-disk file.
call append('$', [':hidden', '# comment', 'new-file', 'new-folder/'])
call feedkeys(":sort size\<CR>", 'xt')
call assert_equal(':hidden', getline(5))
call assert_equal('# comment', getline(6))
call assert_equal(8, line('$'))
call assert_equal(sort([s:dir, s:renamed, s:small, s:close, ':hidden', '# comment', 'new-file', 'new-folder/']), sort(getline(1, '$')))

" The chosen order survives navigation; headers stay at the top.
call writefile(['# header', s:large, s:small, s:close, s:dir], s:root . '/next.lstf')
call writefile(['# header'], s:root . '/next.lstf.header')
execute 'edit! ' . fnameescape(s:root . '/next.lstf')
call assert_equal(['# header', s:dir, s:small, s:close, s:large], getline(1, '$'))
call assert_false(&modified)
call feedkeys(":sort! size\<CR>", 'xt')
call assert_equal(['# header', s:dir, s:large, s:close, s:small], getline(1, '$'))

" Native options still use Vim's sort; normal text buffers are unaffected.
new
call setline(1, ['20 z', '3 a'])
call feedkeys(":sort n\<CR>", 'xt')
call assert_equal(['3 a', '20 z'], getline(1, '$'))
call feedkeys(":sort\<CR>", 'xt')
call assert_equal(['20 z', '3 a'], getline(1, '$'))

call delete(s:root, 'rf')
if !empty(v:errors)
  call writefile(v:errors, '/tmp/lstf-sort-errors')
  cquit
endif
qa!
