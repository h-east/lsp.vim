# lsp.vim

[![Test](https://github.com/h-east/lsp.vim/actions/workflows/test.yml/badge.svg)](https://github.com/h-east/lsp.vim/actions/workflows/test.yml)
[![Update doc/tags](https://github.com/h-east/lsp.vim/actions/workflows/update-doc-tags.yml/badge.svg)](https://github.com/h-east/lsp.vim/actions/workflows/update-doc-tags.yml)
[![Vim 9.2.0997+](https://img.shields.io/badge/Vim-9.2.0997%2B-015b01?logo=vim&logoColor=white)](#requirements)

A Language Server Protocol client for Vim, written in Vim9 script.

Vim frames the protocol messages and matches replies to requests itself, so
what is left to the plugin is the conversation and what to do with the
answers.

It is written as much to put Vim's own side of the protocol through its
paces as to be used every day, and some of what turned up that way has gone
into Vim itself.  Expect it to move at that pace rather than at the pace of
a plugin its author leans on all day.

## Requirements

- Vim 9.2.0997 or later, with the `+job` and `+channel` features.  That patch
  is what lets `ch_sendexpr()` answer a request the server named with a
  string, and 9.2.0970 before it is what lets `listener_add()` ask for the
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

What the client itself does goes in `g:lsp_client_config`, one entry per
setting:

```vim
g:lsp_client_config = {
  highlight_delay: 150,
  inlay_hint: true,
}
```

Every key that can go in there, and what it is when it is left out, is
listed under `:help lsp-configuration`.

A buffer is connected to the server for its `'filetype'` when it is opened.
The server is started once per workspace root.

## Suggested settings

Completion goes through `'omnifunc'`, which Vim uses only where it is told
to, so a few options decide whether much of this shows up at all:

```vim
def LspBuffer()
  # 'autocomplete' offers what 'complete' names.  This one asks the server
  # where a word has begun or after a character the server calls a trigger,
  # rather than after every key the way "o" would.
  setlocal complete^=Flsp#AutoComplete
  setlocal autocomplete
  # "menuone" for a single match, "popup" for the resolved documentation.
  setlocal completeopt=menuone,popup
  # So the text stays put as a sign comes and goes.
  setlocal signcolumn=yes

  nnoremap <buffer> K  <Cmd>LspHover<CR>
  nnoremap <buffer> gd <Cmd>LspDefinition<CR>
enddef

# Whatever the servers say they handle, so adding one above is enough.
const LspFiletypes = g:lsp_server_list
      ->mapnew((_, c) => c.filetypes)->flattennew()->join(',')

augroup lsprc
  autocmd!
  execute 'autocmd FileType' LspFiletypes 'LspBuffer()'
augroup END
```

`'autocompletedelay'` is global rather than per buffer, so it goes on its
own: `set autocompletedelay=500` keeps the menu from opening between
keystrokes.  Asking the server is a wait, and `completion_timeout` is what
bounds it.

## Servers it has been used with

- clangd 18.1.3, for C and C++
- pylsp 1.15.0, for Python
- gopls 0.18.0, for Go

Only what a server says it offers is asked for, and the three differ enough
to be worth naming.  clangd answers a type hierarchy, semantic tokens and a
formatting request for a range, and offers no code lens; its call hierarchy
answers who calls a function, while `callHierarchy/outgoingCalls` comes back
as an unknown method.  pylsp offers a code lens, and offers no workspace
symbol search, no inlay hints and no call hierarchy.  gopls offers a code
lens, inlay hints and semantic tokens, and neither a type hierarchy nor a
formatting request for a range; it is the only one of the three that asks at
run time to be told about files it is not being sent.  gopls and pylsp take
more than one workspace folder, clangd says nothing of it and so gets a
process per root.

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
- Hover, and jumps to a definition, declaration, type or implementation
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
|  | `:LspInlayHintInfo` | What the server says about the hint here |
|  | `:LspInlayHintApply` | Put what the hint here says into the file |
|  | `:LspFolding` | Turn the folds from the server on or off |
|  | `:LspCodeLens` | Turn the code lenses on or off |
|  | `:LspCodeLensRun` | Run the lens above this line |
|  | `:LspSemanticTokens` | Turn the coloring from the server on or off |

See `:help lsp.txt` for the options and the details.

## TODO

Where this client stands against what a server can offer.  The ones that
would be felt first:

- [x] `textDocument/semanticTokens/full`, `/range` and `/full/delta`, the
      highlighting a server works out from what it parsed
- [x] The token modifiers, `readonly` and `deprecated` among them
- [x] `textDocument/diagnostic`, the pull kind
- [x] `textDocument/prepareRename`, to turn a rename down before it is sent
      and to start from the name the server names
- [x] Dynamic registration and `workspace/didChangeWatchedFiles`, as far as
      Vim can tell that a file changed
- [x] Snippets, `insertTextFormat` 2, stepped through with
      `<Plug>(lsp-snippet-next)`, asked for with `snippet`

Worth having:

- [x] `codeAction/resolve`, `codeLens/resolve` and `workspaceSymbol/resolve`
- [x] `inlayHint/resolve`, with `:LspInlayHintInfo` and
      `:LspInlayHintApply` to act on a hint
- [x] `window/showMessageRequest` and `window/showDocument`
- [x] `textDocument/willSave` and `textDocument/willSaveWaitUntil`
- [x] The file operations, with `:LspRenameFile`; nothing here deletes a
      file, so `willDeleteFiles` and `didDeleteFiles` are declared off
- [x] The refresh requests for code lenses, inlay hints, semantic tokens
      and diagnostics

Smaller:

- [ ] `textDocument/documentLink` and its resolve
- [ ] `textDocument/selectionRange`
- [ ] `textDocument/linkedEditingRange`
- [ ] `textDocument/onTypeFormatting`
- [ ] `textDocument/documentColor` and `colorPresentation`
- [ ] `textDocument/inlineValue`, `moniker` and `inlineCompletion`
- [x] More than one workspace folder for a server that takes them
- [x] A `positionEncoding` other than UTF-16, UTF-8 for choice
- [ ] The completion `context`, and asking again for a list that came back
      incomplete

## Tests

```
cd test && ./run
```

```
VIMPROG=/path/to/vim ./run       # which Vim to test, "vim" by default
TEST_FILTER=rename ./run         # only the tests whose name matches
```

The results are printed and also left in `test/messages`, and the exit status
says whether anything failed.  A Vim too old for the plugin is reported as
such rather than failing every test on a missing command.

They run against `test/fakeserver.py`, which answers from a scenario file
rather than being a real language server: the scenario says what capabilities
to announce, what to send unprompted, and what to reply to each request with.
It records everything the client sent, so a test can check that as well as
what the client did with the answers.

## AI

This plugin is developed with the support of AI (Claude).

## License

Same terms as Vim itself: the Vim license, in `LICENSE` here and under
`:help license`.
