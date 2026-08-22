# lsp.vim

A Language Server Protocol client for Vim, written in Vim9 script.

Vim frames the protocol messages and matches replies to requests itself, so
what is left to the plugin is the conversation and what to do with the
answers.

## Requirements

- Vim 9.2.970 or later, with the `+job` and `+channel` features.  That patch
  is what lets `listener_add()` ask for the text of a change, which is how a
  buffer is kept in step with the server.
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

Describe the servers to use in `g:lsp_servers`:

```vim
g:lsp_servers = [{
  name: 'clangd',
  filetypes: ['c', 'cpp'],
  cmd: ['clangd', '--background-index', '--clang-tidy'],
  rootPatterns: ['compile_commands.json', '.git'],
}]
```

A buffer is connected to the server for its `'filetype'` when it is opened.
The server is started once per workspace root.

## What it does

- Completion through `'omnifunc'`, including `completionItem/resolve` for the
  info popup
- Diagnostics as signs, text highlights and a message on the cursor line
- Signature help while a call is being typed
- The other places the symbol under the cursor is used, marked in the buffer
- Inlay hints, the names and types a server fills in, off until asked for
- Folds worked out by the server, off until asked for
- Hover, and jumps to a definition, declaration, type or implementation
- Every mention of a symbol, the symbols in a file, and a workspace-wide
  symbol search
- Who calls a function and what it calls
- Rename across files, whole-buffer formatting, and code actions from a menu
- Incremental document synchronisation with `listener_add()`
- What the server reports about itself: messages, logs, and what it is busy
  with
- Changes the server works out on its own, including an action it carries out
  itself

## Commands

| Category | Command | Description |
| --- | --- | --- |
| Server | `:LspStart` | Connect this buffer to the server for its filetype |
|  | `:LspStop` | Shut down every running server |
|  | `:LspStatus` | List the running servers |
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
|  | `:LspOutline` | The symbols in this buffer, into the location list |
|  | `:LspSymbol {query}` | Search the workspace for symbols |
|  | `:LspDiag` | The diagnostics, into the location list |
| Changing | `:LspCodeAction` | Offer what the server can do here |
|  | `:LspRename [{name}]` | Rename the symbol everywhere |
|  | `:LspFormat` | Format this buffer, or `:{range}LspFormat` for part of it |
| Display | `:LspInlayHint` | Turn the inlay hints on or off |
|  | `:LspFolding` | Turn the folds from the server on or off |

See `:help lsp.txt` for the options and the details.

## TODO

Signature help:

- [x] `:LspSignature` on its own.
- [x] `g:lsp_signature_help` set to `false`.
- [x] The popup going below the cursor when the completion menu sits above it.

Requests:

- [x] `textDocument/references`
- [x] `textDocument/rename`
- [x] `textDocument/formatting`
- [x] `textDocument/codeAction`
- [x] `workspace/symbol`

Other:

- [x] `additionalTextEdits` in a completion item, such as an include to add.
- [x] `window/logMessage`, `window/showMessage` and `$/progress`.
- [x] Diagnostics carry `relatedInformation`.
- [x] A `textEdit` reaching wider than the word before the cursor, as long as
      it stays within the line.

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

## License

Same terms as Vim itself.  See `:help license`.
