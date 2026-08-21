vim9script noclear

# LSP client for Vim
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21
#
# Install it with a plugin manager (Plug 'h-east/lsp.vim') or as an optional
# package loaded with "packadd! lsp", and describe the servers to use in
# g:lsp_servers.  See |lsp.txt|.

# Patch 9.2.970 is what lets listener_add() ask for the text of a change,
# which is how the buffer is kept in step with the server.
if !has('job') || !has('channel') || !has('patch-9.2.970')
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
command! -bar LspDeclaration lsp.Declaration()
command! -bar LspTypeDefinition lsp.TypeDefinition()
command! -bar LspImplementation lsp.Implementation()
command! -bar LspReferences lsp.References()
command! -bar LspOutline    lsp.Outline()
command! -bar -nargs=1 LspSymbol lsp.Symbol(<q-args>)
command! -bar LspFormat     lsp.Format()
command! -bar -nargs=? LspRename lsp.Rename(<q-args>)
command! -bar -range LspCodeAction lsp.CodeAction(<line1>, <line2>)
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
