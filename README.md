# lsp.vim

A Language Server Protocol client for Vim, written in Vim9 script.

Vim frames the protocol messages and matches replies to requests itself, so
what is left to the plugin is the conversation and what to do with the
answers.

## Requirements

- Vim with the `+job` and `+channel` features
- A language server for the language you work in, installed separately

## Installation

With a plugin manager, vim-plug for instance:

```vim
Plug 'h-east/lsp.vim'
```

Or as an optional package, put it under `pack/*/opt/lsp` and load it from your
vimrc:

```vim
packadd! lsp
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
- Hover and jump to definition
- Incremental document synchronisation with `listener_add()`

## Commands

| Command | Description |
| --- | --- |
| `:LspStart` | Connect the current buffer to the server for its filetype |
| `:LspStop` | Shut down every running server |
| `:LspStatus` | List the running servers |
| `:LspHover` | Show what the server knows about the symbol under the cursor |
| `:LspDefinition` | Jump to the definition of the symbol under the cursor |
| `:LspSignature` | Show what the call the cursor is in takes |
| `:LspDiag` | Put the diagnostics into the location list |
| `:LspLog` | Open what the server wrote to its standard error |

See `:help lsp.txt` for the options and the details.

## License

Same terms as Vim itself.  See `:help license`.
