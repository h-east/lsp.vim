vim9script noclear

# LSP client for Vim
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21
#
# Install it with a plugin manager (Plug 'h-east/lsp.vim') or as an optional
# package loaded with "packadd! lsp", and describe the servers to use in
# g:lsp_servers.  See |lsp.txt|.

if !has('job') || !has('channel')
  finish
endif

import autoload '../autoload/lsp.vim'

if !exists('g:lsp_servers')
  g:lsp_servers = []
endif

command! -bar LspStart      lsp.Attach()
command! -bar LspStop       lsp.Stop()
command! -bar LspStatus     lsp.Status()
command! -bar LspHover      lsp.Hover()
command! -bar LspDefinition lsp.Definition()
command! -bar LspSignature  lsp.Signature()
command! -bar LspDiag       lsp.Diagnostics()
command! -bar LspLog        lsp.Log()

# Defining the autocommand does not load the autoload script, the first
# FileType event for a buffer with a configured server does.
augroup lsp
  autocmd!
  autocmd FileType * lsp.Attach()
augroup END

# vim: sw=2 sts=2 et
