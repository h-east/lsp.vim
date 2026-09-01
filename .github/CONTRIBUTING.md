# Contributing

Issue reports are welcome.  Patches are read too, but a report that shows what
a server sent is usually worth more than a diff: the fix is written here, in
the style the rest of it is written in.

## What it is written against

The LSP specification and what servers actually do.  Where the two disagree,
what the server sent is what settles it.

Other LSP clients are deliberately left out of it, their source as much as
their documentation, and a patch carrying code from one cannot be taken.
Please point at the specification, or at a server, rather than at another
client.

## Reporting

A report is easiest to act on with the language server named, a file small
enough to paste, and the keys to press in it.  `:LspStatus` names which server
a buffer talks to and how far it got, and `:LspLog` holds what the server
logged and what it wrote to its standard error.  The messages themselves are
in Vim's channel log, which `ch_logfile()` starts.

## Patches

A change in behavior belongs with a test that fails without it, and with the
lines in `doc/lsp.txt` that describe it.  The plugin is Vim9 script
throughout, two spaces of indent.

The tests are in `test/`:

```
cd test && ./run
```

```
VIMPROG=/path/to/vim ./run       # which Vim to test, "vim" by default
TEST_FILTER=rename ./run         # only the tests whose name matches
```

The results are printed and also left in `test/messages`, and the exit status
reports whether anything failed.  A Vim too old for the plugin is reported as
such rather than failing every test on a missing command.

They run against `test/fakeserver.py`, which answers from a scenario file
rather than being a real language server: the scenario names the capabilities
to announce, what to send unprompted, and what to reply to each request with.
It records everything the client sent, so a test can check that as well as
what the client did with the answers.
