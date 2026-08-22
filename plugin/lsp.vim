vim9script

# LSP client for Vim
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21
#
# Install it with a plugin manager (Plug 'h-east/lsp.vim') or as an optional
# package loaded with "packadd! lsp.vim", and describe the servers to use in
# g:lsp_server_list.  See |lsp.txt|.

# Patch 9.2.970 is what lets listener_add() ask for the text of a change,
# which is how the buffer is kept in step with the server.
if !has('job') || !has('channel') || !has('patch-9.2.970')
  # Nothing is said on startup, so leave one command to ask.
  def Unsupported()
    echohl WarningMsg
    echomsg 'lsp: needs Vim 9.2.970 with +job and +channel'
    echohl None
  enddef
  command! -bar LspStatus Unsupported()
  finish
endif

import autoload '../autoload/lsp.vim'

if !exists('g:lsp_server_list')
  g:lsp_server_list = []
endif
if !exists('g:lsp_client_config')
  g:lsp_client_config = {}
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
command! -bar LspIncomingCalls lsp.IncomingCalls()
command! -bar LspOutgoingCalls lsp.OutgoingCalls()
command! -bar LspSuperTypes lsp.SuperTypes()
command! -bar LspSubTypes   lsp.SubTypes()
command! -bar LspOutline    lsp.Outline()
command! -bar LspInlayHint  lsp.ToggleInlayHints()
command! -bar LspCodeLens   lsp.ToggleCodeLens()
command! -bar LspCodeLensRun lsp.RunCodeLens()
command! -bar LspFolding    lsp.ToggleFolding()
command! -bar -nargs=1 LspSymbol lsp.Symbol(<q-args>)
command! -bar -range=% LspFormat lsp.Format(<line1>, <line2>)
command! -bar -nargs=? LspRename lsp.Rename(<q-args>)
command! -bar -range LspCodeAction lsp.CodeAction(<line1>, <line2>)
command! -bar LspSignature  lsp.Signature()
command! -bar LspDiag       lsp.Diagnostics()
command! -bar LspLog        lsp.Log()

# Kept out of the autoload script, because reaching that script is what this
# decides: a file nothing is configured for leaves the plugin asleep.
def HasServer(): bool
  for config in get(g:, 'lsp_server_list', [])
    if type(config) == v:t_dict
	  && index(config->get('filetypes', []), &filetype) >= 0
      return true
    endif
  endfor
  return false
enddef

augroup lsp
  autocmd!
  autocmd FileType * if HasServer() | lsp.Attach() | endif
augroup END

# vim: sw=2 sts=2 et
