vim9script
# What democast plays.  Read both by the recording script, to learn what to
# open, and by Vim itself, as the vimrc for the session.
#
#   ~/.vim/plugged/democast.vim/bin/democast
#
# The everyday vimrc is read first, as it would be; this only adds the demo.

g:democast = {
  dir: expand('~/samba/github/vim/src'),
  file: 'main.c',
  steps: [
    ['keys', '', '', 600],              # let the server attach
    ['type', '/^common_init_1', '', 400],
    ['keys', "\<CR>", '↩', 1000],
    ['keys', 'j', 'j', 300],
    # Up the screen a little, so the menu has room below the cursor and the
    # signature keeps the room above to itself.
    ['keys', "\<C-E>", '<C-E>', 300],
    ['keys', 'o', 'o', 700],
    # The menu narrows as the word is typed; at the everyday 500 the typing
    # would be over before it opened.
    ['cmd', 'set autocompletedelay=50', '', 100],
    ['slow', 'ch_log', '', 800],        # the menu narrows with each letter
    ['keys', "\<C-N>", '<C-N>', 300],   # the documentation comes with it
    ['keys', "\<C-N>", '<C-N>', 200],   # the documentation comes with it
    ['keys', "\<C-N>", '<C-N>', 800],   # the documentation comes with it
    ['type', '(', '', 600],             # "(" takes the match and the signature
    ['type', 'NULL, ', '', 600],        # and moves on to the next argument
    ['type', '"%s", ', '', 600],        # and moves on to the next argument
    ['type', '"Hello");', '', 800],
    ['keys', "\<Esc>", '<Esc>', 300],
    ['keys', '^', '^', 600],
    ['keys', 'K', 'K', 2200],           # what the server knows about it
    ['keys', "\<Esc>", '<Esc>', 800],
    ['keys', 'gd', 'gd', 2200],         # to where it is defined
    ['type', ':LspReferences', '', 300],  # every mention of it
    ['keys', "\<CR>", '↩', 2200],
    ['type', ':cclose', '', 300],
    ['keys', "\<CR>", '↩', 1600],
  ],
  before: ['set cmdheight=1'],
}

# vim: ts=2 sw=0 et
