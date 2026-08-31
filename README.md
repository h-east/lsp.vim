# lsp.vim

[![Test](https://github.com/h-east/lsp.vim/actions/workflows/test.yml/badge.svg)](https://github.com/h-east/lsp.vim/actions/workflows/test.yml)
[![Update doc/tags](https://github.com/h-east/lsp.vim/actions/workflows/update-doc-tags.yml/badge.svg)](https://github.com/h-east/lsp.vim/actions/workflows/update-doc-tags.yml)
[![Vim 9.2.1004+](https://img.shields.io/badge/Vim-9.2.1004%2B-015b01?logo=vim&logoColor=white)](#requirements)

A Language Server Protocol client for Vim, written in Vim9 script.

Vim frames the protocol messages and matches replies to requests itself, so
what is left to the plugin is the conversation and what to do with the
answers.

It is written as much to put Vim's own side of the protocol through its
paces as to be used every day, and some of what turned up that way has gone
into Vim itself.  Expect it to move at that pace rather than at the pace of
a plugin its author leans on all day.

## Requirements

- Vim 9.2.1004 or later, with the `+job` and `+channel` features.  That patch
  is what lets a completion function tell whether Vim asked on its own,
  9.2.0997 before it is what lets `ch_sendexpr()` answer a request the server
  named with a string, and 9.2.0970 what lets `listener_add()` ask for the
  text of a change, which is how a buffer is kept in step with the server.
- A language server for the language you work in, installed separately

## Installation

With a plugin manager, vim-plug for instance:

```vim
Plug 'h-east/lsp.vim'
```

Or as an optional package, put it under `pack/*/opt/lsp.vim` and load it from
your vimrc:

```vim
packadd! lsp.vim
```

## Configuration

Describe the servers to use in `g:lsp_server_list`:

```vim
g:lsp_server_list = [{
  name: 'clangd',
  filetypes: ['c', 'cpp'],
  cmd: ['clangd', '--background-index', '--clang-tidy',
	'--header-insertion=never'],
  rootPatterns: ['compile_commands.json', '.git'],
}, {
  name: 'pylsp',
  filetypes: ['python'],
  cmd: ['pylsp'],
  rootPatterns: ['pyproject.toml', '.git'],
}, {
  name: 'gopls',
  filetypes: ['go'],
  cmd: ['gopls'],
  rootPatterns: ['go.work', 'go.mod', '.git'],
}]
```

<details>
<summary>For legacy Vim script</summary>

```vim
let g:lsp_server_list = [
      \ #{name: 'clangd',
      \   filetypes: ['c', 'cpp'],
      \   cmd: ['clangd', '--background-index', '--clang-tidy',
      \         '--header-insertion=never'],
      \   rootPatterns: ['compile_commands.json', '.git']},
      \ #{name: 'pylsp',
      \   filetypes: ['python'],
      \   cmd: ['pylsp'],
      \   rootPatterns: ['pyproject.toml', '.git']},
      \ #{name: 'gopls',
      \   filetypes: ['go'],
      \   cmd: ['gopls'],
      \   rootPatterns: ['go.work', 'go.mod', '.git']},
      \ ]
```

</details>

What the client itself does goes in `g:lsp_client_config`, one entry per
setting:

```vim
g:lsp_client_config = {
  highlight_delay: 150,
  inlay_hint: true,
}
```

<details>
<summary>For legacy Vim script</summary>

```vim
let g:lsp_client_config = #{
      \ highlight_delay: 150,
      \ inlay_hint: v:true,
      \ }
```

</details>

Every key that can go in there, and what it is when it is left out, is
listed under `:help lsp-configuration`.

The hover, code action and signature popups take the border `'pumopt'` names
for the completion menu, so setting that is enough for all four to match:

```vim
set pumopt=border:round
```

Each popup can be asked for on its own instead, in `'pumopt'` and
`'winhighlight'` format; see `:help lsp-popup`.

A buffer is connected to the server for its `'filetype'` when it is opened.
The server is started once per workspace root.

## Suggested settings

Completion goes through `'omnifunc'`, which Vim uses only where it is told
to, so a few options decide whether much of this shows up at all:

```vim
def LspBuffer()
  # 'autocomplete' offers what 'complete' names, and "o" names 'omnifunc',
  # which the plugin has set.
  setlocal complete^=o
  setlocal autocomplete
  # "menuone" for a single match, "popup" for the resolved documentation.
  setlocal completeopt=menuone,popup
  # So the text stays put as a sign comes and goes.
  setlocal signcolumn=yes

  nnoremap <buffer> K  <Cmd>LspHover<CR>
  nnoremap <buffer> gd <Cmd>LspDefinition<CR>
enddef

# Whatever filetypes the servers cover, so adding one above is enough.
const LspFiletypes = g:lsp_server_list
      ->mapnew((_, c) => c.filetypes)->flattennew()->join(',')

augroup lsprc
  autocmd!
  execute 'autocmd FileType' LspFiletypes 'LspBuffer()'
augroup END
```

<details>
<summary>For legacy Vim script</summary>

```vim
function! s:LspBuffer()
  " 'autocomplete' offers what 'complete' names, and "o" names 'omnifunc',
  " which the plugin has set.
  setlocal complete^=o
  setlocal autocomplete
  " "menuone" for a single match, "popup" for the resolved documentation.
  setlocal completeopt=menuone,popup
  " So the text stays put as a sign comes and goes.
  setlocal signcolumn=yes

  nnoremap <buffer> K  <Cmd>LspHover<CR>
  nnoremap <buffer> gd <Cmd>LspDefinition<CR>
endfunction

" Whatever filetypes the servers cover, so adding one above is enough.
let s:lsp_filetypes = g:lsp_server_list
      \ ->mapnew({_, c -> c.filetypes})->flattennew()->join(',')

augroup lsprc
  autocmd!
  execute 'autocmd FileType' s:lsp_filetypes 'call s:LspBuffer()'
augroup END
```

</details>

`'autocompletedelay'` is global rather than per buffer, so it goes on its
own: `set autocompletedelay=500` keeps the menu from opening between
keystrokes.  Asking the server is a wait, and `completion_timeout` is what
bounds it.

## Servers it has been used with

- clangd 18.1.3, for C and C++
- pylsp 1.15.0, for Python
- gopls 0.18.0, for Go

Only what a server offers is asked for, and the three differ enough to be
worth naming.  clangd answers a type hierarchy, semantic tokens and a
formatting request for a range, and offers no code lens; its call hierarchy
answers who calls a function, while `callHierarchy/outgoingCalls` comes back
as an unknown method.  pylsp offers a code lens, and offers no workspace
symbol search, no inlay hints and no call hierarchy.  gopls offers a code
lens, inlay hints and semantic tokens, and neither a type hierarchy nor a
formatting request for a range; it is the only one of the three that asks at
run time to be told about files it is not being sent.  gopls and pylsp take
more than one workspace folder, clangd supports neither and so gets a process
per root.

## What it does

- Completion through `'omnifunc'`, including `completionItem/resolve` for the
  info popup, and snippets whose stops can be stepped through once `snippet`
  is turned on
- Diagnostics as signs, text highlights and a message on the cursor line,
  whether the server sends them or waits to be asked
- Signature help while a call is being typed
- The other places the symbol under the cursor is used, marked in the buffer
- Semantic tokens, the coloring a server works out from what it parsed, off
  until asked for
- Inlay hints, the names and types a server fills in, off until asked for
- Folds worked out by the server, off until asked for
- Code lenses above the line they are about, off until asked for
- Document links, the parts of a file that lead somewhere else, off until
  asked for
- Growing the selection out to the next range the file is built from, and
  back in, through `<Plug>(lsp-selection-expand)` and its shrink
- Hover, scrolled from the keyboard where it does not fit, and jumps to a
  definition, declaration, type or implementation
- Every mention of a symbol, the symbols in a file, and a workspace-wide
  symbol search
- Who calls a function and what it calls, and what a type is derived
  from or gives rise to
- Rename across files, formatting a buffer or a range, and code actions from
  a menu
- One server for several projects where it takes workspace folders, one per
  root where it does not
- Incremental document synchronization with `listener_add()`
- What the server wants changed on the way to disk, waited for before the
  write
- What the server reports about itself: messages, logs, and what it is busy
  with
- What the server asks of the editor: a message to answer, a file to look
  at, and what has gone out of date and should be asked for again
- Changes the server works out on its own, including an action it carries out
  itself
- Files the server asked to watch, reported when Vim writes one or notices
  that it changed

## Commands

| Category | Command | Description |
| --- | --- | --- |
| Server | `:LspStart` | Connect this buffer to the server for its filetype |
|  | `:LspStop` | Shut down every running server |
|  | `:LspStatus` | List the running servers |
|  | `:LspConfigCheck` | Report what in `g:lsp_client_config` or `g:lsp_server_list` cannot be read |
|  | `:LspConfigReload` | Tell every running server that its settings changed |
|  | `:LspWorkspaceFolderAdd [{dir}]` | Hand a directory to this server as another workspace folder |
|  | `:LspWorkspaceFolderRemove {dir}` | Take a workspace folder back from this server |
|  | `:LspLog` | Open what the server has logged |
| Asking | `:LspHover` | What the server knows about the symbol |
|  | `:LspSignature` | What the call the cursor is in takes |
| Jumping | `:LspDefinition` | Jump to the definition of the symbol |
|  | `:LspDeclaration` | Jump to the declaration, a prototype in C |
|  | `:LspTypeDefinition` | Jump to the definition of the symbol's type |
|  | `:LspImplementation` | Jump to what implements the symbol |
| Lists | `:LspReferences` | Every mention, into the quickfix list |
|  | `:LspIncomingCalls` | Who calls the function under the cursor |
|  | `:LspOutgoingCalls` | What the function under the cursor calls |
|  | `:LspSuperTypes` | The types this one is derived from |
|  | `:LspSubTypes` | The types derived from this one |
|  | `:LspOutline` | The symbols in this buffer, into the location list |
|  | `:LspSymbol {query}` | Search the workspace for symbols |
|  | `:LspDiag` | The diagnostics, into the location list |
| Changing | `:LspCodeAction` | Offer what the server can do here |
|  | `:LspRename [{name}]` | Rename the symbol everywhere |
|  | `:LspRenameFile [{name}]` | Rename this file, imports and all |
|  | `:LspFormat` | Format this buffer, or a range of it |
| Display | `:LspInlayHint` | Turn the inlay hints on or off |
|  | `:LspInlayHintInfo` | What the server reports about the hint here |
|  | `:LspInlayHintApply` | Put the hint here into the file |
|  | `:LspFolding` | Turn the folds from the server on or off |
|  | `:LspCodeLens` | Turn the code lenses on or off |
|  | `:LspCodeLensRun` | Run the lens above this line |
|  | `:LspDocumentLink` | Turn the document links on or off |
|  | `:LspDocumentLinkOpen` | Go where the link under the cursor leads |
|  | `:LspDocumentLinkInfo` | What the server reports about that link |
|  | `:LspSemanticTokens` | Turn the coloring from the server on or off |

See `:help lsp.txt` for the options and the details.

## Protocol coverage

What this client does with each of the 95 requests and notifications in
the LSP 3.18 meta model: 73 are answered, 1 more is worth having, and
21 are left out for the reason given.

<details>
<summary>Method-by-method tables</summary>

### Lifecycle

| Method | State | Note |
| --- | --- | --- |
| `initialize` | yes |  |
| `initialized` | yes |  |
| `shutdown` | yes |  |
| `exit` | yes |  |
| `client/registerCapability` | yes | what a server asks for at run time |
| `client/unregisterCapability` | yes |  |
| `$/cancelRequest` | yes |  |
| `$/progress` | yes | both the server's work and its own requests |
| `$/setTrace` | no | `:LspLog` shows what the server logs anyway |
| `$/logTrace` | no | nothing asks for a trace |

### Keeping the server in step with the buffer

| Method | State | Note |
| --- | --- | --- |
| `textDocument/didOpen` | yes |  |
| `textDocument/didChange` | yes | incremental, through `listener_add()` |
| `textDocument/didSave` | yes |  |
| `textDocument/didClose` | yes |  |
| `textDocument/willSave` | yes |  |
| `textDocument/willSaveWaitUntil` | yes | waited for before the write |
| `notebookDocument/didOpen` | no | Vim has no notebook to open |
| `notebookDocument/didChange` | no |  |
| `notebookDocument/didSave` | no |  |
| `notebookDocument/didClose` | no |  |

### Language features

| Method | State | Note |
| --- | --- | --- |
| `textDocument/completion` | yes | with the context and `isIncomplete` |
| `completionItem/resolve` | yes | for the documentation popup |
| `textDocument/hover` | yes | `:LspHover` |
| `textDocument/signatureHelp` | yes | `:LspSignature` |
| `textDocument/declaration` | yes | `:LspDeclaration` |
| `textDocument/definition` | yes | `:LspDefinition` |
| `textDocument/typeDefinition` | yes | `:LspTypeDefinition` |
| `textDocument/implementation` | yes | `:LspImplementation` |
| `textDocument/references` | yes | `:LspReferences` |
| `textDocument/documentHighlight` | yes | the other uses of the symbol |
| `textDocument/documentSymbol` | yes | `:LspOutline` |
| `textDocument/codeAction` | yes | `:LspCodeAction` |
| `codeAction/resolve` | yes |  |
| `textDocument/codeLens` | yes | `:LspCodeLens` |
| `codeLens/resolve` | yes |  |
| `textDocument/documentLink` | yes | `:LspDocumentLink` |
| `documentLink/resolve` | yes |  |
| `textDocument/foldingRange` | yes | `:LspFolding` |
| `textDocument/selectionRange` | yes | `<Plug>(lsp-selection-expand)` |
| `textDocument/prepareCallHierarchy` | yes |  |
| `callHierarchy/incomingCalls` | yes | `:LspIncomingCalls` |
| `callHierarchy/outgoingCalls` | yes | `:LspOutgoingCalls` |
| `textDocument/prepareTypeHierarchy` | yes |  |
| `typeHierarchy/supertypes` | yes | `:LspSuperTypes` |
| `typeHierarchy/subtypes` | yes | `:LspSubTypes` |
| `textDocument/semanticTokens/full` | yes | `:LspSemanticTokens` |
| `textDocument/semanticTokens/full/delta` | yes |  |
| `textDocument/semanticTokens/range` | yes |  |
| `textDocument/inlayHint` | yes | `:LspInlayHint` |
| `inlayHint/resolve` | yes | `:LspInlayHintInfo`, `:LspInlayHintApply` |
| `textDocument/publishDiagnostics` | yes | what a server sends unasked |
| `textDocument/diagnostic` | yes | what a server waits to be asked for |
| `textDocument/formatting` | yes | `:LspFormat` |
| `textDocument/rangeFormatting` | yes | `:{range}LspFormat` |
| `textDocument/rangesFormatting` | no | Vim has one range at a time |
| `textDocument/onTypeFormatting` | no | clangd answers by removing the indent |
| `textDocument/rename` | yes | `:LspRename` |
| `textDocument/prepareRename` | yes | turns a rename down before it is sent |
| `textDocument/linkedEditingRange` | no | clangd and gopls do not offer it |
| `textDocument/documentColor` | no | clangd and gopls do not offer it |
| `textDocument/colorPresentation` | no |  |
| `textDocument/inlineValue` | no | for a debugger, which this is not |
| `textDocument/inlineCompletion` | no | clangd and gopls do not offer it |
| `textDocument/moniker` | no | clangd and gopls do not offer it |

### Workspace

| Method | State | Note |
| --- | --- | --- |
| `workspace/symbol` | yes | `:LspSymbol` |
| `workspaceSymbol/resolve` | yes |  |
| `workspace/configuration` | yes | answered from `settings` in the server entry |
| `workspace/didChangeConfiguration` | yes | `:LspConfigReload` |
| `workspace/workspaceFolders` | yes |  |
| `workspace/didChangeWorkspaceFolders` | yes | `:LspWorkspaceFolderAdd`, `:LspWorkspaceFolderRemove` |
| `workspace/didChangeWatchedFiles` | yes | for the files a server asks to watch |
| `workspace/executeCommand` | yes | for a code action or lens the server runs |
| `workspace/applyEdit` | yes | changes the server works out on its own |
| `workspace/diagnostic` | planned | diagnostics are pulled a buffer at a time |
| `workspace/willCreateFiles` | yes |  |
| `workspace/didCreateFiles` | yes |  |
| `workspace/willRenameFiles` | yes | `:LspRenameFile` |
| `workspace/didRenameFiles` | yes |  |
| `workspace/willDeleteFiles` | no | nothing here deletes a file |
| `workspace/didDeleteFiles` | no |  |
| `workspace/codeLens/refresh` | yes |  |
| `workspace/inlayHint/refresh` | yes |  |
| `workspace/semanticTokens/refresh` | yes |  |
| `workspace/diagnostic/refresh` | yes |  |
| `workspace/foldingRange/refresh` | yes |  |
| `workspace/inlineValue/refresh` | no |  |
| `workspace/textDocumentContent` | no | for a document the server makes up |
| `workspace/textDocumentContent/refresh` | no |  |

### Window

| Method | State | Note |
| --- | --- | --- |
| `window/showMessage` | yes |  |
| `window/showMessageRequest` | yes | an answer is picked from a menu |
| `window/logMessage` | yes | `:LspLog` |
| `window/showDocument` | yes | opens it here, or hands a URI to `:URLOpen` |
| `window/workDoneProgress/create` | yes |  |
| `window/workDoneProgress/cancel` | no | clangd and gopls never mark their work cancellable |
| `telemetry/event` | no | there is nowhere to send it |

</details>

## Contributing

How a report or a patch is best put, and how the tests are run, is in
[CONTRIBUTING](.github/CONTRIBUTING.md).

## AI

This plugin is developed with the support of AI (Claude).

## License

Same terms as Vim itself: the Vim license, in `LICENSE` here and under
`:help license`.
