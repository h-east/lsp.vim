vim9script noclear

# LSP client for Vim
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21
#
# Install it with a plugin manager (Plug 'h-east/lsp.vim') or as an optional
# package loaded with "packadd! lsp.vim", and describe the servers to use in
# g:lsp_server_list.  See |lsp.txt|.

if exists('g:loaded_lsp_vim')
  finish
endif
g:loaded_lsp_vim = 1

# Patch 9.2.1004 is what lets a completion function tell whether Vim asked on
# its own or a key asked for a menu.
if !has('job') || !has('channel') || !has('patch-9.2.1004')
  # Nothing is reported on startup, so leave one command to ask.
  def Unsupported()
    echohl WarningMsg
    echomsg 'lsp: needs Vim 9.2.1004 with +job and +channel'
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

def FolderNames(arglead: string, _: string, _: number): list<string>
  return lsp.RemovableFolders()->filter((_, f) => f->stridx(arglead) == 0)
enddef

command! -bar LspStart      lsp.Attach(true)
command! -bar LspStop       lsp.Stop(true)
command! -bar LspStatus     lsp.Status()
command! -bar LspConfigCheck lsp.ConfigCheck()
command! -bar LspConfigReload lsp.ConfigReload()
command! -bar -nargs=? -complete=dir LspWorkspaceFolderAdd {
  lsp.WorkspaceFolderAdd(<q-args>)
}
command! -bar -nargs=1 -complete=customlist,FolderNames LspWorkspaceFolderRemove {
  lsp.WorkspaceFolderRemove(<q-args>)
}
command! -bar LspHover      lsp.Hover()
command! -bar LspDefinition lsp.Definition(<q-mods>)
command! -bar LspDeclaration lsp.Declaration(<q-mods>)
command! -bar LspTypeDefinition lsp.TypeDefinition(<q-mods>)
command! -bar LspImplementation lsp.Implementation(<q-mods>)
command! -bar LspReferences lsp.References()
command! -bar LspIncomingCalls lsp.IncomingCalls()
command! -bar LspOutgoingCalls lsp.OutgoingCalls()
command! -bar LspSuperTypes lsp.SuperTypes()
command! -bar LspSubTypes   lsp.SubTypes()
command! -bar LspOutline    lsp.Outline()
command! -bar LspInlayHint  lsp.ToggleInlayHints()
command! -bar LspInlayHintApply lsp.InlayHintApply()
command! -bar LspInlayHintInfo lsp.InlayHintInfo()
command! -bar LspCodeLens   lsp.ToggleCodeLens()
command! -bar LspCodeLensRun lsp.RunCodeLens()
command! -bar LspDocumentLink lsp.ToggleDocumentLink()
command! -bar LspDocumentLinkOpen lsp.OpenDocumentLink()
command! -bar LspDocumentLinkInfo lsp.DocumentLinkInfo()
command! -bar LspFolding    lsp.ToggleFolding()
command! -bar LspSemanticTokens lsp.ToggleSemanticTokens()
command! -bar -nargs=1 LspSymbol lsp.Symbol(<q-args>)
command! -bar -range=% LspFormat lsp.Format(<line1>, <line2>)
command! -bar -nargs=? LspRename lsp.Rename(<q-args>)
command! -bar -nargs=? -complete=file LspRenameFile lsp.RenameFile(<q-args>)
command! -bar -range LspCodeAction lsp.CodeAction(<line1>, <line2>)
command! -bar LspSignature  lsp.Signature()
command! -bar LspDiag       lsp.Diagnostics()
command! -bar LspWorkspaceDiag lsp.WorkspaceDiagnostics()
command! -bar LspLog        lsp.Log()

# Nothing is bound to these; see |lsp-snippet|.
inoremap <expr> <Plug>(lsp-snippet-next) lsp.SnippetKeys(1)
inoremap <expr> <Plug>(lsp-snippet-prev) lsp.SnippetKeys(-1)
snoremap <expr> <Plug>(lsp-snippet-next) lsp.SnippetKeys(1)
snoremap <expr> <Plug>(lsp-snippet-prev) lsp.SnippetKeys(-1)

# Nor to this one; see |lsp-document-link|.
nnoremap <silent> <Plug>(lsp-document-link) <Cmd>LspDocumentLinkOpen<CR>

# Nor to these; see |lsp-selection|.
nnoremap <silent> <Plug>(lsp-selection-expand) <Cmd>lsp#SelectionExpand()<CR>
xnoremap <silent> <Plug>(lsp-selection-expand) <Cmd>lsp#SelectionExpand()<CR>
xnoremap <silent> <Plug>(lsp-selection-shrink) <Cmd>lsp#SelectionShrink()<CR>

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

# test/run sets this to have every :def compiled as the script is read.
if $LSP_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
