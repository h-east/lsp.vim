vim9script
# Tests for the LSP client.  Run them with test/run.

import './helper.vim' as t

# The message history holds every file that was opened as well.
def LastMessage(): string
  return split(execute('messages'), "\n")->get(-1, '')
enddef

# Document sync is all a server has to offer for a buffer to be handed over.
const SYNC: dict<any> = {textDocumentSync: 2}

def Offering(what: dict<any>): dict<any>
  return extend(SYNC->copy(), what)
enddef

# The guard finishes before anything is defined again, so a second read must
# leave what the first one put there alone.
def g:Test_the_plugin_can_be_read_again()
  const PLUGIN = fnamemodify(t.SRC, ':h:h') .. '/plugin/lsp.vim'
  execute 'source ' .. fnameescape(PLUGIN)

  # Attaching runs a script-local function of that script.
  assert_true(t.StartServer({capabilities: SYNC}, ['int one;']))
enddef

def g:Test_snippets_are_asked_for_only_when_they_are_wanted()
  assert_true(t.StartServer({capabilities: SYNC}, ['int one;']))
  var caps = t.Sent('initialize')[0].params.capabilities
  assert_false(caps.textDocument.completion.completionItem.snippetSupport)

  t.StopServer()
  g:lsp_client_config = {snippet: true}
  defer remove(g:, 'lsp_client_config')
  assert_true(t.StartServer({capabilities: SYNC}, ['int one;']))
  caps = t.Sent('initialize')[0].params.capabilities
  assert_true(caps.textDocument.completion.completionItem.snippetSupport)
enddef

def g:Test_what_a_server_takes_at_startup_is_handed_over()
  const OPTIONS = {semanticTokens: true, analyses: {unusedparams: true}}
  assert_true(t.StartServer({capabilities: SYNC}, ['int one;'],
			    {initializationOptions: OPTIONS}))

  assert_equal(OPTIONS, t.Sent('initialize')[0].params.initializationOptions)
enddef

def g:Test_a_server_set_up_with_nothing_is_handed_nothing()
  assert_true(t.StartServer({capabilities: SYNC}, ['int one;']))

  # Not an empty Dictionary: a server tells the two apart.
  assert_false(t.Sent('initialize')[0].params
		  ->has_key('initializationOptions'))
enddef

def g:Test_didopen_carries_the_text()
  assert_true(t.StartServer({capabilities: SYNC},
			    ['int main(void)', '{', '    return 0;', '}']),
	      'the server should come up')

  # The document follows the handshake, so it may still be on its way.
  assert_true(t.WaitFor(() => !t.Sent('textDocument/didOpen')->empty()),
	      'the document should be sent')
  var opened = t.Sent('textDocument/didOpen')
  assert_equal(1, len(opened))
  var doc = opened[0].params.textDocument
  assert_equal("int main(void)\n{\n    return 0;\n}\n", doc.text)
  assert_equal('c', doc.languageId)
  assert_match('/Xsrc\.c$', doc.uri)
enddef

def g:Test_a_change_is_sent_as_a_range()
  assert_true(t.StartServer({capabilities: SYNC}, ['one', 'two', 'three']))

  setline(2, 'TWO')
  listener_flush()
  assert_true(t.WaitFor(() => !t.Sent('textDocument/didChange')->empty()),
	      'the change should go out')

  var changes = t.Sent('textDocument/didChange')[0].params.contentChanges
  assert_equal(1, len(changes))
  assert_equal({line: 1, character: 0}, changes[0].range.start)
  assert_equal({line: 2, character: 0}, changes[0].range.end)
  assert_equal("TWO\n", changes[0].text)
enddef

def g:Test_diagnostics_reach_the_location_list()
  const REPORT = {
    range: {start: {line: 2, character: 4}, end: {line: 2, character: 10}},
    severity: 2,
    source: 'test',
    message: 'a warning',
    relatedInformation: [{
      location: {uri: 'file://' .. t.SRC,
		 range: {start: {line: 0, character: 4},
			 end: {line: 0, character: 8}}},
      message: 'declared here',
    }],
  }
  assert_true(t.StartServer({
    capabilities: SYNC,
    notify: [{method: 'textDocument/publishDiagnostics',
	      params: {uri: 'file://' .. t.SRC, diagnostics: [REPORT]}}],
  }, ['int main(void)', '{', '    return 0;', '}']))

  assert_true(t.WaitFor(() =>
	    !sign_getplaced('%', {group: 'lsp'})[0].signs->empty()),
	    'a sign should be placed')

  LspDiag
  var items = getloclist(0)
  assert_equal(2, len(items), 'the report and what it points at')
  assert_equal(3, items[0].lnum)
  assert_equal(5, items[0].col)
  assert_equal('W', items[0].type)
  assert_equal('[test] a warning', items[0].text)
  assert_equal(1, items[1].lnum)
  assert_equal('  declared here', items[1].text)
  lclose
enddef

const TRIGGERS = {resolveProvider: false, triggerCharacters: ['.']}

# What Vim asks on its own, rather than 'omnifunc': "keys" is typed at the end
# of "line", which is what drives the completion.  Only one character is
# typed, so what goes out is what that character brought on.
def TypeInto(line: string, keys: string): bool
  var ok = t.StartServer({
    capabilities: Offering({completionProvider: TRIGGERS}),
    replies: {'textDocument/completion': {isIncomplete: false, items: []}},
  }, ['int main(void)', '{', line, '}'])
  setlocal complete=o
  setlocal autocomplete
  # Autocompletion holds off while a key is waiting, which is all feedkeys()
  # ever leaves.
  test_override('char_avail', 1)
  cursor(3, 1)
  feedkeys('A' .. keys .. "\<Esc>", 'tx')
  return ok
enddef

def CleanUp()
  test_override('ALL', 0)
  setlocal noautocomplete
  setlocal complete=.,w,b,u,t,i
enddef

def g:Test_nothing_is_asked_for_where_a_word_does_not_start()
  assert_true(TypeInto('    ', '('))
  assert_false(t.WaitFor(() =>
			 !t.Sent('textDocument/completion')->empty(), 200),
	       'the server should be left alone after a bracket')
  CleanUp()
enddef

# The server is told why it is being asked; see |completion-context|.
def g:Test_the_server_is_told_why_it_was_asked()
  assert_true(TypeInto('    (', '.'))
  assert_true(t.WaitFor(() => !t.Sent('textDocument/completion')->empty()),
	      'the server should be asked after a trigger character')
  assert_equal({triggerKind: 2, triggerCharacter: '.'},
	       t.Sent('textDocument/completion')[0].params.context)
  CleanUp()
enddef

# A list the server cut short is asked for again as the word grows, rather
# than narrowed down here.
def g:Test_a_list_the_server_cut_short_is_asked_for_again()
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: TRIGGERS}),
    replies: {'textDocument/completion': {isIncomplete: true, items: [
		    {label: 'alpha'}, {label: 'alphabet'}]}},
  }, ['int main(void)', '{', '    al', '}']))

  cursor(3, 7)
  call('lsp#OmniFunc', [1, ''])
  var answer = call('lsp#OmniFunc', [0, 'al'])
  assert_equal(v:t_dict, type(answer))
  assert_equal('always', answer.refresh)
  assert_equal(['alpha', 'alphabet'],
	       answer.words->mapnew((_, w) => w.word))
  assert_equal(1, t.Sent('textDocument/completion')[0].params.context.triggerKind)

  # The next round says it is asking again about the same list.
  call('lsp#OmniFunc', [0, 'alp'])
  assert_equal(3,
	       t.Sent('textDocument/completion')[1].params.context.triggerKind)
  doautocmd CompleteDone
enddef

# What the server said about one list does not carry into the next.
def g:Test_a_list_cut_short_does_not_outlive_its_completion()
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: TRIGGERS}),
    replies: {'textDocument/completion': {isIncomplete: true, items: [
		    {label: 'alpha'}, {label: 'alphabet'}]}},
  }, ['int main(void)', '{', '    al', '}']))

  cursor(3, 7)
  call('lsp#OmniFunc', [1, ''])
  call('lsp#OmniFunc', [0, 'al'])
  call('lsp#OmniFunc', [1, ''])
  call('lsp#OmniFunc', [0, 'alp'])
  doautocmd CompleteDone
  call('lsp#OmniFunc', [1, ''])
  call('lsp#OmniFunc', [0, 'al'])

  # Asked, asked again about the same list, and asked afresh.
  assert_equal([1, 3, 1], t.Sent('textDocument/completion')
	->mapnew((_, m) => m.params.context.triggerKind))
  doautocmd CompleteDone
enddef

def g:Test_a_trigger_character_is_a_place_to_complete()
  assert_true(TypeInto('    (', '.'))
  assert_true(t.WaitFor(() => !t.Sent('textDocument/completion')->empty()),
	      'the server should be asked after a trigger character')
  CleanUp()
enddef

def g:Test_what_is_asked_for_by_hand_reaches_the_server_anywhere()
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: TRIGGERS}),
    replies: {'textDocument/completion': {isIncomplete: false, items: []}},
  }, ['int main(void)', '{', '    f(', '}']))

  cursor(3, 1)
  feedkeys("A\<C-X>\<C-O>\<Esc>", 'tx')
  assert_true(t.WaitFor(() => !t.Sent('textDocument/completion')->empty()),
	      'CTRL-X CTRL-O should ask even after a bracket')
  # Nothing brought it on, a key asked for it.
  assert_equal({triggerKind: 1},
	       t.Sent('textDocument/completion')[0].params.context)
enddef

# A key asking through the entry in 'complete' is not held to a place worth
# completing at, the way what Vim asks on its own is.
def g:Test_a_key_asking_through_complete_reaches_the_server_too()
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: TRIGGERS}),
    replies: {'textDocument/completion': {isIncomplete: false, items: []}},
  }, ['int main(void)', '{', '    f(', '}']))

  setlocal complete=o
  cursor(3, 1)
  feedkeys("A\<C-N>\<Esc>", 'tx')
  assert_true(t.WaitFor(() => !t.Sent('textDocument/completion')->empty()),
	      'CTRL-N should ask even after a bracket')
  CleanUp()
enddef

def g:Test_the_edits_around_a_completed_word()
  const ITEM = {
    label: 'printf',
    filterText: 'printf',
    insertText: 'printf',
    insertTextFormat: 1,
    kind: 3,
    additionalTextEdits: [{
      newText: "#include <stdio.h>\n",
      range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}},
    }],
  }
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: {resolveProvider: false}}),
    replies: {'textDocument/completion': {isIncomplete: false, items: [ITEM]}},
  }, ['int main(void)', '{', '    prin', '}']))

  cursor(3, 8)
  feedkeys("A\<C-X>\<C-O>\<C-Y>\<Esc>", 'tx')
  # The edits around the word land after the event that carries the word.
  assert_true(t.WaitFor(() => getline(1) ==# '#include <stdio.h>'),
	      'the include should be added')
  assert_equal('    printf', getline(4))
enddef

# Where the cursor is left has to be read while Insert mode is still on, so
# it is read from the typeahead itself.
var stopped_at: list<number> = []

def g:SnippetStop(): string
  stopped_at = [line('.'), col('.')]
  return ''
enddef

def g:Test_a_snippet_is_put_in_with_its_stops_taken_out()
  const ITEM = {
    label: 'demo',
    filterText: 'demo',
    insertTextFormat: 2,
    kind: 3,
    textEdit: {
      # Written against the line as it is when the server is asked, which is
      # from the column completion starts at.
      range: {start: {line: 2, character: 4}, end: {line: 2, character: 4}},
      newText: 'demo(${1:int a}, ${2:int b})',
    },
  }
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: {resolveProvider: false}}),
    replies: {'textDocument/completion': {isIncomplete: false, items: [ITEM]}},
  }, ['int main(void)', '{', '    dem', '}']))

  cursor(3, 7)
  feedkeys("A\<C-X>\<C-O>\<C-Y>\<C-R>=g:SnippetStop()\<CR>\<Esc>", 'tx')
  assert_equal('    demo(int a, int b)', getline(3))
  # On the first stop, ready for it to be typed over.
  assert_equal([3, 10], stopped_at)
enddef

def g:Test_a_snippet_may_reach_over_more_than_one_line()
  const ITEM = {
    label: 'do',
    filterText: 'do',
    insertTextFormat: 2,
    kind: 15,
    textEdit: {
      range: {start: {line: 2, character: 4}, end: {line: 2, character: 4}},
      newText: "do {\n\n} while ($0);",
    },
  }
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: {resolveProvider: false}}),
    replies: {'textDocument/completion': {isIncomplete: false, items: [ITEM]}},
  }, ['int main(void)', '{', '    d', '}']))

  cursor(3, 5)
  feedkeys("A\<C-X>\<C-O>\<C-Y>\<C-R>=g:SnippetStop()\<CR>\<Esc>", 'tx')
  assert_equal(['    do {', '', '} while ();'], getline(3, 5))
  # "$0" wins over the first stop.
  assert_equal([5, 10], stopped_at)
enddef

def g:Test_the_stops_of_a_snippet_are_stepped_through()
  const ITEM = {
    label: 'demo',
    filterText: 'demo',
    insertTextFormat: 2,
    kind: 3,
    textEdit: {
      range: {start: {line: 2, character: 4}, end: {line: 2, character: 4}},
      newText: 'demo(${1:int a}, ${2:int b})$0',
    },
  }
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: {resolveProvider: false}}),
    replies: {'textDocument/completion': {isIncomplete: false, items: [ITEM]}},
  }, ['int main(void)', '{', '    dem', '}']))

  imap <buffer> <F5> <Plug>(lsp-snippet-next)
  smap <buffer> <F5> <Plug>(lsp-snippet-next)
  imap <buffer> <F6> <Plug>(lsp-snippet-prev)
  smap <buffer> <F6> <Plug>(lsp-snippet-prev)

  cursor(3, 7)
  feedkeys("A\<C-X>\<C-O>\<C-Y>", 'tx')

  # Each stop in turn is selected, so what it stands for is typed over, and
  # going back reaches the one before.
  feedkeys("i\<F5>\<F5>\<F6>A\<Esc>", 'tx')
  assert_equal('    demo(A, int b)', getline(3))

  # "$0" comes after the numbered ones, wherever it is written.
  feedkeys("i\<F5>B\<F5>!\<Esc>", 'tx')
  assert_equal('    demo(A, B)!', getline(3))
enddef

def g:Test_the_next_snippet_starts_at_its_own_first_stop()
  const ITEM = {
    label: 'demo',
    filterText: 'demo',
    insertTextFormat: 2,
    kind: 3,
    textEdit: {
      range: {start: {line: 2, character: 4}, end: {line: 2, character: 4}},
      newText: 'demo(${1:int a}, ${2:int b})',
    },
  }
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: {resolveProvider: false}}),
    replies: {'textDocument/completion': {isIncomplete: false, items: [ITEM]}},
  }, ['int main(void)', '{', '    dem', '}']))

  imap <buffer> <F5> <Plug>(lsp-snippet-next)
  smap <buffer> <F5> <Plug>(lsp-snippet-next)

  # Step into the first one, so that there is something to be left behind.
  cursor(3, 7)
  feedkeys("A\<C-X>\<C-O>\<C-Y>", 'tx')
  feedkeys("i\<F5>\<F5>\<Esc>", 'tx')

  # Another one, with a line of its own above it: taking an item with CTRL-Y
  # while the cursor is moved from CompleteDone copies a character from the
  # line above, which an empty one has none of.
  append(3, ['', '    dem'])
  cursor(5, 7)
  feedkeys("A\<C-X>\<C-O>\<C-Y>", 'tx')
  assert_equal('    demo(int a, int b)', getline(5))

  # Stepping on reaches the first stop of the new one, rather than carrying
  # on from where the one before was left.
  assert_match('cursor(5, 10)', lsp#SnippetKeys(1))
enddef

def Answered(id: string): list<dict<any>>
  return t.Trace()->filter((_, m) => string(m->get('id', '')) ==# "'" .. id
								      .. "'")
enddef

def g:Test_a_message_comes_with_answers_to_pick_from()
  defer popup_clear()
  assert_true(t.StartServer({
    capabilities: Offering({definitionProvider: true}),
    replies: {'textDocument/definition': v:null},
    ask: {'textDocument/definition': [{
      id: 'ask',
      method: 'window/showMessageRequest',
      params: {type: 3, message: 'start over?',
	       actions: [{title: 'Yes'}, {title: 'No'}]},
    }]},
  }, ['int one;']))

  LspDefinition
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'the answers should be put in a menu')
  # The menu takes the first entry on <CR>.
  feedkeys("\<CR>", 'tx')
  assert_true(t.WaitFor(() => !Answered('ask')->empty()),
	      'the server should be told what was picked')
  assert_equal('Yes', Answered('ask')[0].result.title)
enddef

def g:Test_the_server_asks_for_a_file_to_be_looked_at()
  const OTHER = t.SRC->substitute('\.c$', '_more.c', '')
  writefile(['int here;', 'int there;'], OTHER)
  defer delete(OTHER)
  assert_true(t.StartServer({
    capabilities: Offering({definitionProvider: true}),
    replies: {'textDocument/definition': v:null},
    ask: {'textDocument/definition': [{
      id: 'show',
      method: 'window/showDocument',
      params: {uri: 'file://' .. OTHER,
	       selection: {start: {line: 1, character: 4},
			   end: {line: 1, character: 9}}},
    }]},
  }, ['int one;']))

  LspDefinition
  assert_true(t.WaitFor(() => !Answered('show')->empty()),
	      'the server should be told how it went')
  assert_true(Answered('show')[0].result.success)
  assert_match('_more\.c$', bufname('%'), 'the file should be open')
  assert_equal([2, 5], [line('.'), col('.')], 'at the place it named')
enddef

def g:Test_the_server_puts_the_file_right_on_the_way_to_disk()
  assert_true(t.StartServer({
    capabilities: {textDocumentSync: {change: 2, willSave: true,
				      willSaveWaitUntil: true}},
    replies: {'textDocument/willSaveWaitUntil': [{
      newText: '#include <stdio.h>',
      range: {start: {line: 0, character: 0}, end: {line: 0, character: 8}},
    }]},
  }, ['#include', 'int one;']))

  write
  # The write waits for the answer, so the change is in the file as well.
  assert_equal('#include <stdio.h>', getline(1))
  assert_equal('#include <stdio.h>', readfile(t.SRC)->get(0, ''))
  assert_equal(1, len(t.Sent('textDocument/willSave')),
	       'the server is told first, then asked')
  assert_equal(1, t.Sent('textDocument/willSave')[0].params.reason)
enddef

def g:Test_renaming_a_file_takes_what_refers_to_it_along()
  const OTHER = t.SRC->substitute('\.c$', '_moved.c', '')
  defer delete(OTHER)
  const FILE_OPS = {fileOperations: {
    willRename: {filters: [{pattern: {glob: '**/*.c', matches: 'file'}}]},
    didRename: {filters: [{pattern: {glob: '**/*.c', matches: 'file'}}]},
  }}
  assert_true(t.StartServer({
    capabilities: extend(Offering({}), {workspace: FILE_OPS}),
    replies: {'workspace/willRenameFiles': {changes: {['file://' .. t.SRC]: [{
      newText: '// moved',
      range: {start: {line: 0, character: 0}, end: {line: 0, character: 8}},
    }]}}},
  }, ['int one;', 'int two;']))

  execute 'LspRenameFile ' .. fnameescape(OTHER)

  # What the server said had to change is in before the file moves.
  assert_equal('// moved', getline(1))
  assert_match('_moved\.c$', bufname('%'), 'the buffer should follow')
  assert_true(filereadable(OTHER), 'the file should be there under its new name')
  assert_false(filereadable(t.SRC), 'and gone from the old one')

  assert_true(t.WaitFor(() => !t.Sent('workspace/didRenameFiles')->empty()),
	      'the server should be told it moved')
  assert_match('Xsrc\.c is now Xsrc_moved\.c, the server was told',
	       LastMessage())
  var told = t.Sent('workspace/didRenameFiles')[0].params.files[0]
  assert_match('Xsrc\.c$', told.oldUri)
  assert_match('_moved\.c$', told.newUri)
enddef

def g:Test_the_commands_say_what_they_did()
  assert_true(t.StartServer({capabilities: SYNC}, ['int one;']))

  LspStart
  assert_match('already has a server', LastMessage())

  LspStop
  assert_match('1 server stopped', LastMessage())
  LspStop
  assert_match('no server was running', LastMessage())
enddef

def g:Test_a_file_that_is_there_is_not_written_over()
  const OTHER = t.SRC->substitute('\.c$', '_taken.c', '')
  writefile(['do not lose me'], OTHER)
  defer delete(OTHER)
  assert_true(t.StartServer({capabilities: SYNC}, ['int one;']))

  execute 'LspRenameFile ' .. fnameescape(OTHER)
  assert_equal(['do not lose me'], readfile(OTHER), 'it should be untouched')
  assert_true(filereadable(t.SRC), 'and the file should not have moved')
  assert_match('Xsrc\.c$', bufname('%'))
enddef

def g:Test_the_server_asks_for_things_to_be_asked_for_again()
  g:lsp_client_config.semantic_tokens = true
  defer execute('unlet g:lsp_client_config.semantic_tokens')
  assert_true(t.StartServer({
    capabilities: Offering({
      definitionProvider: true,
      semanticTokensProvider: {legend: LEGEND, full: true},
      diagnosticProvider: {interFileDependencies: true,
			   workspaceDiagnostics: false},
    }),
    replies: {
      'textDocument/definition': v:null,
      'textDocument/semanticTokens/full': {data: TOKENS},
      'textDocument/diagnostic': {kind: 'full', resultId: '1', items: []},
    },
    ask: {'textDocument/definition': [
      {id: 'sem', method: 'workspace/semanticTokens/refresh', params: v:null},
      {id: 'diag', method: 'workspace/diagnostic/refresh', params: v:null},
    ]},
  }, SOURCE))

  assert_true(t.WaitFor(() =>
		    len(t.Sent('textDocument/semanticTokens/full')) == 1),
	      'asked for once to start with')
  var first = len(t.Sent('textDocument/diagnostic'))

  LspDefinition
  assert_true(t.WaitFor(() => !Answered('sem')->empty()
			      && !Answered('diag')->empty()),
	      'both should be answered')
  assert_true(t.WaitFor(() =>
		    len(t.Sent('textDocument/semanticTokens/full')) == 2),
	      'the tokens should be asked for again')
  assert_true(t.WaitFor(() =>
		    len(t.Sent('textDocument/diagnostic')) > first),
	      'the diagnostics should be asked for again')
  assert_false(t.Sent('textDocument/diagnostic')[-1].params
		->has_key('previousResultId'),
	       'what was reported before no longer stands')
enddef

def g:Test_a_second_root_is_added_to_the_server_that_is_running()
  const DIR = t.SRC->substitute('/[^/]*$', '/Xelsewhere', '')
  mkdir(DIR .. '/.git', 'p')
  defer delete(DIR, 'rf')
  writefile(['int two;'], DIR .. '/Xtwo.c')
  assert_true(t.StartServer({
    capabilities: extend(Offering({}), {workspace: {workspaceFolders: {
      supported: true,
      changeNotifications: 'workspace/didChangeWorkspaceFolders',
    }}}),
    ask: {'textDocument/didSave': []},
  }, ['int one;']))

  # The root it started with goes out with the handshake.
  var folders = t.Sent('initialize')[0].params.workspaceFolders
  assert_equal(1, len(folders))

  execute 'edit ' .. fnameescape(DIR .. '/Xtwo.c')
  setfiletype c
  assert_true(t.WaitFor(() =>
	      !t.Sent('workspace/didChangeWorkspaceFolders')->empty()),
	      'the server should be told about the other root')
  var added = t.Sent('workspace/didChangeWorkspaceFolders')[0]
		  .params.event.added
  assert_equal(1, len(added))
  assert_match('Xelsewhere/\=$', added[0].uri)

  # One server, not two; the folders it holds go under its own line.
  assert_equal(1, execute('LspStatus')->split("\n")
			->filter((_, l) => l =~# 'fake@')->len())
enddef

def g:Test_a_folder_is_added_and_taken_back_by_hand()
  const DIR = t.SRC->substitute('/[^/]*$', '/Xlibrary', '')
  mkdir(DIR, 'p')
  defer delete(DIR, 'rf')
  assert_true(t.StartServer({
    capabilities: extend(Offering({}), {workspace: {workspaceFolders: {
      supported: true,
      changeNotifications: 'workspace/didChangeWorkspaceFolders',
    }}}),
  }, ['int one;']))

  execute 'LspWorkspaceFolderAdd ' .. fnameescape(DIR)
  assert_match('now covers .*Xlibrary$', LastMessage())
  assert_true(t.WaitFor(() =>
	      !t.Sent('workspace/didChangeWorkspaceFolders')->empty()),
	      'the server should be told about the folder')
  var event = t.Sent('workspace/didChangeWorkspaceFolders')[0].params.event
  assert_equal([], event.removed)
  assert_equal(1, len(event.added))
  assert_match('Xlibrary/\=$', event.added[0].uri)
  assert_equal('Xlibrary', event.added[0].name)

  # Both are listed, and only the added one can be taken back.
  assert_match('folders:', execute('LspStatus'))
  assert_equal([DIR], getcompletion('LspWorkspaceFolderRemove ', 'cmdline'))

  execute 'LspWorkspaceFolderRemove ' .. fnameescape(DIR)
  assert_match('no longer covers .*Xlibrary$', LastMessage())
  assert_true(t.WaitFor(() =>
	      len(t.Sent('workspace/didChangeWorkspaceFolders')) == 2),
	      'the server should be told the folder is gone')
  event = t.Sent('workspace/didChangeWorkspaceFolders')[1].params.event
  assert_equal([], event.added)
  assert_equal(1, len(event.removed))
  assert_match('Xlibrary/\=$', event.removed[0].uri)
  assert_equal([], getcompletion('LspWorkspaceFolderRemove ', 'cmdline'))
  assert_notmatch('folders:', execute('LspStatus'))
enddef

def g:Test_a_folder_is_refused_by_a_server_taking_one_root()
  assert_true(t.StartServer({capabilities: SYNC}, ['int one;']))

  execute 'LspWorkspaceFolderAdd '
	  .. fnameescape(t.SRC->substitute('/[^/]*$', '', ''))
  assert_match('does not take workspace folders', LastMessage())
  assert_true(t.Sent('workspace/didChangeWorkspaceFolders')->empty())
enddef

def g:Test_a_position_is_counted_the_way_the_server_said()
  # Three bytes in UTF-8, one unit in UTF-16, one in UTF-32, so which one the
  # server picked shows in the numbers.
  const WIDE = nr2char(0x3042)
  const LINE = 'int ' .. WIDE .. ' = 1;'
  const REPORT = {
    # Byte counted: the name starts at 4 and is three bytes long.
    range: {start: {line: 0, character: 4}, end: {line: 0, character: 7}},
    severity: 1,
    message: 'a fault',
  }
  assert_true(t.StartServer({
    capabilities: {textDocumentSync: 2, positionEncoding: 'utf-8',
		   hoverProvider: true},
    replies: {'textDocument/hover': {contents: 'x'}},
    notify: [{method: 'textDocument/publishDiagnostics',
	      params: {uri: 'file://' .. t.SRC, diagnostics: [REPORT]}}],
  }, [LINE]))

  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the report should be shown')
  var shown = prop_list(1)[0]
  assert_equal([5, 3], [shown.col, shown.length],
	       'the byte columns the server meant')

  # And the same the other way: the cursor after the name is at byte 7.
  popup_clear()
  defer popup_clear()
  cursor(1, 8)
  LspHover
  # Waiting for the popup, not only for the request: an answer that arrives
  # after the test would put one up in the middle of the next one.
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'the server should be asked and answer')
  assert_equal(7, t.Sent('textDocument/hover')[0].params.position.character)
enddef

def g:Test_a_log_message_is_kept_for_LspLog()
  assert_true(t.StartServer({
    capabilities: SYNC,
    notify: [{method: 'window/logMessage',
	      params: {type: 4, message: 'for the record'}}],
  }, ['int x;']))

  # The notification follows "initialized", so it may not have arrived yet.
  # :LspLog goes by the buffer it is called from and opens one of its own, so
  # each look starts from the source buffer again.
  const SRC_BUF = bufnr('%')
  var found = false
  for _ in range(40)
    execute 'buffer ' .. SRC_BUF
    silent! LspLog
    if getline(1) ==# '--- window/logMessage ---'
      found = true
      break
    endif
    sleep 25m
  endfor
  assert_true(found, 'the message should be kept for :LspLog')
  assert_equal('for the record', getline(2))
enddef

def g:Test_references_land_in_the_quickfix_list()
  const HERE = {uri: 'file://' .. t.SRC,
		range: {start: {line: 0, character: 4},
			end: {line: 0, character: 7}}}
  const THERE = {uri: 'file://' .. t.SRC,
		 range: {start: {line: 1, character: 4},
			 end: {line: 1, character: 7}}}
  assert_true(t.StartServer({
    capabilities: Offering({referencesProvider: true}),
    replies: {'textDocument/references': [HERE, THERE]},
  }, ['int one;', 'int two;']))

  cursor(1, 5)
  LspReferences
  assert_true(t.WaitFor(() => len(getqflist()) == 2),
	      'both mentions should be listed')
  var items = getqflist()
  assert_equal([1, 5, 'int one;'],
	       [items[0].lnum, items[0].col, items[0].text])
  assert_equal([2, 5, 'int two;'],
	       [items[1].lnum, items[1].col, items[1].text])
  cclose
enddef

def g:Test_rename_changes_what_the_server_says()
  var edit = {
    newText: 'ONE',
    range: {start: {line: 0, character: 4}, end: {line: 0, character: 7}},
  }
  assert_true(t.StartServer({
    capabilities: Offering({renameProvider: true}),
    replies: {'textDocument/rename':
	      {changes: {['file://' .. t.SRC]: [edit]}}},
  }, ['int one;', 'int two;']))

  cursor(1, 5)
  LspRename ONE
  assert_true(t.WaitFor(() => getline(1) ==# 'int ONE;'),
	      'the name should be replaced')
  assert_equal('int two;', getline(2))
enddef

def g:Test_a_rename_is_turned_down_before_it_is_sent()
  assert_true(t.StartServer({
    capabilities: Offering({renameProvider: {prepareProvider: true}}),
    # Nothing at all: there is no name at the cursor to rename.
    replies: {'textDocument/prepareRename': v:null},
  }, ['int one;']))

  cursor(1, 4)
  LspRename ONE
  assert_true(t.WaitFor(() =>
		    !t.Sent('textDocument/prepareRename')->empty()),
	      'the server should be asked first')
  assert_true(t.WaitFor(() => LastMessage() =~# 'no name to rename'),
	      'the answer should be passed on')
  assert_equal([], t.Sent('textDocument/rename'),
	       'a rename the server turned down should not be sent')
  assert_equal('int one;', getline(1))
enddef

def g:Test_the_rename_goes_ahead_once_the_server_allows_it()
  var edit = {
    newText: 'ONE',
    range: {start: {line: 0, character: 4}, end: {line: 0, character: 7}},
  }
  assert_true(t.StartServer({
    capabilities: Offering({renameProvider: {prepareProvider: true}}),
    replies: {
      # A bare range, which is what a server answers with when the name is
      # the text it covers.
      'textDocument/prepareRename': {start: {line: 0, character: 4},
				     end: {line: 0, character: 7}},
      'textDocument/rename': {changes: {['file://' .. t.SRC]: [edit]}},
    },
  }, ['int one;']))

  cursor(1, 5)
  LspRename ONE
  assert_true(t.WaitFor(() => getline(1) ==# 'int ONE;'),
	      'the name should be replaced')
enddef

def g:Test_format_replaces_the_buffer_in_one_undo()
  var edit = {
    newText: "int main(void)\n{\n    return 0;\n}",
    range: {start: {line: 0, character: 0}, end: {line: 3, character: 1}},
  }
  assert_true(t.StartServer({
    capabilities: Offering({documentFormattingProvider: true}),
    replies: {'textDocument/formatting': [edit]},
  }, ['int  main(void)', '{', '  return 0;', '}']))

  LspFormat
  assert_true(t.WaitFor(() => getline(1) ==# 'int main(void)'),
	      'the buffer should be formatted')
  assert_equal('    return 0;', getline(3))

  undo
  assert_equal('int  main(void)', getline(1))
  assert_equal('  return 0;', getline(3))
enddef

def g:Test_format_asks_about_the_range_it_was_given()
  var edit = {
    newText: '    return 0;',
    range: {start: {line: 2, character: 0}, end: {line: 2, character: 11}},
  }
  assert_true(t.StartServer({
    capabilities: Offering({documentRangeFormattingProvider: true}),
    replies: {'textDocument/rangeFormatting': [edit]},
  }, ['int  main(void)', '{', '  return 0;', '}']))

  :2,3LspFormat
  assert_true(t.WaitFor(() => getline(3) ==# '    return 0;'),
	      'the range should be formatted')
  # The first line is outside the range, so it is left as it is.
  assert_equal('int  main(void)', getline(1))

  var asked = t.Sent('textDocument/rangeFormatting')
  assert_equal(1, len(asked))
  assert_equal({line: 1, character: 0}, asked[0].params.range.start)
  assert_equal({line: 2, character: 11}, asked[0].params.range.end)

  # This server formats a range and nothing else, so the whole buffer is not
  # on offer.
  LspFormat
  assert_match('does not offer formatting', LastMessage())
  assert_true(t.Sent('textDocument/formatting')->empty())
enddef

def g:Test_an_edit_wider_than_the_word()
  # The server wants "obj->fie" to become "obj.field", which is more than the
  # word before the cursor that omni completion can replace on its own.
  const ITEM = {
    label: 'field',
    filterText: 'fie',
    insertText: 'field',
    insertTextFormat: 1,
    kind: 5,
    textEdit: {
      newText: '.field',
      range: {start: {line: 2, character: 7}, end: {line: 2, character: 12}},
    },
  }
  assert_true(t.StartServer({
    capabilities: Offering({completionProvider: {resolveProvider: false}}),
    replies: {'textDocument/completion': {isIncomplete: false, items: [ITEM]}},
  }, ['int main(void)', '{', '    obj->fie', '}']))

  cursor(3, 12)
  feedkeys("A\<C-X>\<C-O>\<C-Y>\<Esc>", 'tx')
  assert_equal('    obj.field', getline(3))

  # Both what completion did and the fix belong to the one keystroke.
  undo
  assert_equal('    obj->fie', getline(3))
enddef

def g:Test_a_save_is_announced()
  assert_true(t.StartServer({
    capabilities: extend(SYNC->copy(),
	{textDocumentSync: {change: 2, save: {includeText: true}}}),
  }, ['int x;']))

  setline(1, 'int y;')
  write
  assert_true(t.WaitFor(() => !t.Sent('textDocument/didSave')->empty()),
	      'the save should be announced')
  var saved = t.Sent('textDocument/didSave')[0].params
  assert_match('/Xsrc\.c$', saved.textDocument.uri)
  # The server asked for the text, so it comes along.
  assert_equal("int y;\n", saved.text)
enddef

def g:Test_a_save_without_the_text()
  assert_true(t.StartServer({capabilities: SYNC}, ['int x;']))

  write
  assert_true(t.WaitFor(() => !t.Sent('textDocument/didSave')->empty()),
	      'the save should be announced')
  assert_false(t.Sent('textDocument/didSave')[0].params->has_key('text'),
	       'the text should be left out when it was not asked for')
enddef

def g:Test_the_server_hands_over_an_edit()
  assert_true(t.StartServer({
    capabilities: Offering({codeActionProvider: true,
			    executeCommandProvider: {commands: ['fix']}}),
    replies: {'textDocument/codeAction': [
      {title: 'let the server do it', command: 'fix', arguments: [1]}]},
    ask: {'workspace/executeCommand': [{
      method: 'workspace/applyEdit',
      params: {edit: {changes: {['file://' .. t.SRC]: [{
	newText: 'ONE',
	range: {start: {line: 0, character: 4},
		end: {line: 0, character: 7}},
      }]}}},
    }]},
  }, ['int one;', 'int two;']))

  LspCodeAction
  # The menu takes the first entry on <CR>.
  assert_true(t.WaitFor(() => !popup_list()->empty()), 'a menu should be up')
  feedkeys("\<CR>", 'tx')

  assert_true(t.WaitFor(() =>
	      !t.Sent('workspace/executeCommand')->empty()),
	      'the command should be sent on')
  var sent = t.Sent('workspace/executeCommand')[0].params
  assert_equal('fix', sent.command)
  assert_equal([1], sent.arguments)

  # Running it, the server hands back the change through applyEdit.
  assert_true(t.WaitFor(() => getline(1) ==# 'int ONE;'),
	      'what the server sent should be applied')
  assert_equal('int two;', getline(2))
enddef

def g:Test_the_rest_of_a_code_action_is_asked_for()
  const EDIT = {
    newText: 'ONE',
    range: {start: {line: 0, character: 4}, end: {line: 0, character: 7}},
  }
  assert_true(t.StartServer({
    capabilities: Offering({codeActionProvider:
			{resolveSupport: {properties: ['edit']}}}),
    replies: {
      # No edit, only what it would be worked out from.
      'textDocument/codeAction': [{title: 'rename it', data: 'the rest'}],
      'codeAction/resolve': {title: 'rename it',
			     edit: {changes: {['file://' .. t.SRC]: [EDIT]}}},
    },
  }, ['int one;', 'int two;']))

  LspCodeAction
  assert_true(t.WaitFor(() => !popup_list()->empty()), 'a menu should be up')
  feedkeys("\<CR>", 'tx')

  assert_true(t.WaitFor(() => getline(1) ==# 'int ONE;'),
	      'the edit that was asked for should be applied')
  assert_equal('the rest', t.Sent('codeAction/resolve')[0].params.data,
	       'the action goes back as it came')
enddef

def g:Test_a_request_named_with_a_string()
  # Vim answers a request of its own accord only when the id is a number, and
  # a server is free to name one with a string.
  const ASKED = 'e8a1-4c2f'
  assert_true(t.StartServer({
    capabilities: Offering({codeActionProvider: true,
			    executeCommandProvider: {commands: ['fix']}}),
    replies: {'textDocument/codeAction': [
      {title: 'let the server do it', command: 'fix', arguments: []}]},
    ask: {'workspace/executeCommand': [{
      id: ASKED,
      method: 'workspace/applyEdit',
      params: {edit: {changes: {['file://' .. t.SRC]: [{
	newText: 'ONE',
	range: {start: {line: 0, character: 4},
		end: {line: 0, character: 7}},
      }]}}},
    }]},
  }, ['int one;']))

  LspCodeAction
  assert_true(t.WaitFor(() => !popup_list()->empty()), 'a menu should be up')
  feedkeys("\<CR>", 'tx')

  assert_true(t.WaitFor(() => getline(1) ==# 'int ONE;'),
	      'what the server sent should be applied')
  # The answer carries the id back as it came, rather than failing to go out.
  var Answers = (): list<dict<any>> => t.Trace()->filter((_, m) =>
			  type(m->get('id', 0)) == v:t_string && m.id ==# ASKED)
  assert_true(t.WaitFor(() => !Answers()->empty()),
	      'the request should be answered')
  assert_equal({applied: true}, Answers()[0].result)
enddef

def g:Test_outline_reads_a_tree_of_symbols()
  # DocumentSymbol nests; the depth shows as indent.
  const TREE = [{
    name: 'main',
    kind: 12,
    range: {start: {line: 0, character: 0}, end: {line: 3, character: 1}},
    selectionRange: {start: {line: 0, character: 4},
		     end: {line: 0, character: 8}},
    children: [{
      name: 'inner',
      kind: 13,
      range: {start: {line: 2, character: 4}, end: {line: 2, character: 14}},
      selectionRange: {start: {line: 2, character: 8},
		       end: {line: 2, character: 13}},
    }],
  }]
  assert_true(t.StartServer({
    capabilities: Offering({documentSymbolProvider: true}),
    replies: {'textDocument/documentSymbol': TREE},
  }, ['int main(void)', '{', '    int inner;', '}']))

  LspOutline
  assert_true(t.WaitFor(() => len(getloclist(0)) == 2),
	      'both symbols should be listed')
  var items = getloclist(0)
  assert_equal([1, 5, '[Function] main'],
	       [items[0].lnum, items[0].col, items[0].text])
  assert_equal([3, 9, '  [Variable] inner'],
	       [items[1].lnum, items[1].col, items[1].text])
  lclose
enddef

def g:Test_outline_reads_a_flat_list_too()
  # SymbolInformation carries a location instead of ranges.
  const FLAT = [{
    name: 'main',
    kind: 12,
    location: {uri: 'file://' .. t.SRC,
	       range: {start: {line: 0, character: 4},
		       end: {line: 0, character: 8}}},
  }]
  assert_true(t.StartServer({
    capabilities: Offering({documentSymbolProvider: true}),
    replies: {'textDocument/documentSymbol': FLAT},
  }, ['int main(void)', '{', '}']))

  LspOutline
  assert_true(t.WaitFor(() => len(getloclist(0)) == 1))
  assert_equal('[Function] main', getloclist(0)[0].text)
  lclose
enddef

def g:Test_a_jump_to_the_declaration()
  assert_true(t.StartServer({
    capabilities: Offering({declarationProvider: true}),
    replies: {'textDocument/declaration': {uri: 'file://' .. t.SRC,
	      range: {start: {line: 2, character: 4},
		      end: {line: 2, character: 7}}}},
  }, ['int one;', 'int two;', 'int three;']))

  cursor(1, 1)
  LspDeclaration
  assert_true(t.WaitFor(() => line('.') == 3), 'the cursor should move')
  assert_equal(5, col('.'))
enddef

def g:Test_a_jump_can_be_stepped_back_from()
  assert_true(t.StartServer({
    capabilities: Offering({definitionProvider: true}),
    replies: {'textDocument/definition': {uri: 'file://' .. t.SRC,
	      range: {start: {line: 2, character: 4},
		      end: {line: 2, character: 9}}}},
  }, ['int one;', 'int two;', 'int three;']))

  settagstack(win_getid(), {items: []})
  defer settagstack(win_getid(), {items: []})
  clearjumps
  defer execute('clearjumps')

  cursor(1, 5)
  LspDefinition
  assert_true(t.WaitFor(() => line('.') == 3), 'the cursor should move')

  const STACK = gettagstack(win_getid())
  assert_equal(1, STACK.length, 'the jump should go on the tag stack')
  assert_equal('one', STACK.items[0].tagname)

  # CTRL-O leads back, though the jump stayed in the file.
  feedkeys("\<C-O>", 'tx')
  assert_equal([1, 5], [line('.'), col('.')])
  feedkeys("\<C-I>", 'tx')
  assert_equal([3, 5], [line('.'), col('.')])

  # So does CTRL-T.
  feedkeys("\<C-T>", 'tx')
  assert_equal([1, 5], [line('.'), col('.')])
enddef

def g:Test_a_jump_can_open_a_window_of_its_own()
  assert_true(t.StartServer({
    capabilities: Offering({definitionProvider: true}),
    replies: {'textDocument/definition': {uri: 'file://' .. t.SRC,
	      range: {start: {line: 2, character: 4},
		      end: {line: 2, character: 9}}}},
  }, ['int one;', 'int two;', 'int three;']))

  only
  defer execute('only')
  cursor(1, 5)
  vertical LspDefinition
  assert_true(t.WaitFor(() => winnr('$') == 2), 'a window should open')
  assert_equal('row', winlayout()[0], 'beside the one it came from')
  assert_equal([3, 5], [line('.'), col('.')], 'the cursor should be in it')

  # A modifier that says nothing about a window opens none.
  only
  cursor(1, 5)
  silent LspDefinition
  assert_true(t.WaitFor(() => line('.') == 3), 'the cursor should move')
  assert_equal(1, winnr('$'), 'in the window it was already in')
enddef

def g:Test_a_request_the_server_does_not_offer()
  assert_true(t.StartServer({capabilities: SYNC}, ['int one;']))

  # Nothing is asked for when the server never said it could answer.
  LspTypeDefinition
  sleep 100m
  assert_true(t.Sent('textDocument/typeDefinition')->empty(),
	      'no request should go out')
enddef

def g:Test_the_symbol_under_the_cursor_is_marked()
  # Two mentions of "one": the second writes to it.
  const MARKS = [
    {range: {start: {line: 0, character: 4}, end: {line: 0, character: 7}},
     kind: 2},
    {range: {start: {line: 2, character: 0}, end: {line: 2, character: 3}},
     kind: 3},
  ]
  assert_true(t.StartServer({
    capabilities: Offering({documentHighlightProvider: true}),
    replies: {'textDocument/documentHighlight': MARKS},
  }, ['int one;', 'int two;', 'one = 1;']))

  # The marks follow a timer, so this waits for it as well as for the reply.
  cursor(1, 5)
  doautocmd CursorMoved
  assert_true(t.WaitFor(() =>
	      len(prop_list(1)) == 1 && len(prop_list(3)) == 1),
	      'both mentions should be marked')

  var read = prop_list(1)[0]
  assert_equal([5, 3, 'LspHighlightRead'],
	       [read.col, read.length, read.type])
  var write = prop_list(3)[0]
  assert_equal([1, 3, 'LspHighlightWrite'],
	       [write.col, write.length, write.type])

  # Moving takes them away again.
  cursor(2, 1)
  doautocmd CursorMoved
  assert_equal([], prop_list(1))
  assert_equal([], prop_list(3))
enddef

def g:Test_the_marks_are_left_alone_when_turned_off()
  g:lsp_client_config.document_highlight = false
  defer execute('unlet g:lsp_client_config.document_highlight')
  assert_true(t.StartServer({
    capabilities: Offering({documentHighlightProvider: true}),
    replies: {'textDocument/documentHighlight': [
      {range: {start: {line: 0, character: 4},
	       end: {line: 0, character: 7}}, kind: 2}]},
  }, ['int one;']))

  cursor(1, 5)
  doautocmd CursorMoved
  sleep 500m
  assert_true(t.Sent('textDocument/documentHighlight')->empty(),
	      'nothing should be asked for')
  assert_equal([], prop_list(1))
enddef

def g:Test_a_document_link_leads_where_the_server_says()
  g:lsp_client_config.document_link = true
  defer execute('unlet g:lsp_client_config.document_link')
  const HEADER = t.SRC->substitute('\.c$', '.h', '')
  writefile(['int one;'], HEADER)
  defer delete(HEADER)
  const LINKS = [
    {range: {start: {line: 0, character: 10}, end: {line: 0, character: 17}},
     target: 'file://' .. HEADER, tooltip: 'the header'},
  ]
  assert_true(t.StartServer({
    capabilities: Offering({documentLinkProvider: {resolveProvider: false}}),
    replies: {'textDocument/documentLink': LINKS},
  }, ['#include "Xsrc.h"', 'int two;']))

  doautocmd BufEnter
  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the link should be marked')
  var shown = prop_list(1)[0]
  assert_equal([11, 7, 'LspDocumentLink'],
	       [shown.col, shown.length, shown.type])

  # What the link says about itself, where it is.
  cursor(1, 12)
  popup_clear()
  defer popup_clear()
  LspDocumentLinkInfo
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'the tooltip should be shown')
  assert_equal('the header',
	       getbufline(winbufnr(popup_list()[0]), 1)->get(0, ''))

  # And where it leads.
  LspDocumentLinkOpen
  assert_equal(fnamemodify(HEADER, ':t'), expand('%:t'))
  execute 'edit ' .. fnameescape(t.SRC)

  # Off again takes the mark out.
  LspDocumentLink
  assert_equal([], prop_list(1))
enddef

def g:Test_a_document_link_the_server_finishes_later()
  g:lsp_client_config.document_link = true
  defer execute('unlet g:lsp_client_config.document_link')
  const HEADER = t.SRC->substitute('\.c$', '.h', '')
  writefile(['int one;'], HEADER)
  defer delete(HEADER)
  const RANGE = {start: {line: 0, character: 10},
		 end: {line: 0, character: 17}}
  assert_true(t.StartServer({
    capabilities: Offering({documentLinkProvider: {resolveProvider: true}}),
    replies: {'textDocument/documentLink': [{range: RANGE, data: 'x'}],
	      'documentLink/resolve': {range: RANGE, data: 'x',
				       target: 'file://' .. HEADER}},
  }, ['#include "Xsrc.h"', 'int two;']))

  doautocmd BufEnter
  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the link should be marked')

  # A link with no target is asked about when it is opened, not before.
  assert_true(t.Sent('documentLink/resolve')->empty(),
	      'the server should be left alone until then')
  cursor(1, 12)
  LspDocumentLinkOpen
  assert_true(t.WaitFor(() =>
		    expand('%:t') ==# fnamemodify(HEADER, ':t')),
	      'the link should lead to the header')
  execute 'edit ' .. fnameescape(t.SRC)
enddef

def g:Test_the_selection_grows_the_way_the_file_is_built()
  # innermost first, each holding the one before it
  const CHAIN = {
    range: {start: {line: 2, character: 8}, end: {line: 2, character: 11}},
    parent: {
      range: {start: {line: 2, character: 4}, end: {line: 2, character: 14}},
      parent: {
	range: {start: {line: 1, character: 0}, end: {line: 3, character: 1}},
      },
    },
  }
  assert_true(t.StartServer({
    capabilities: Offering({selectionRangeProvider: true}),
    replies: {'textDocument/selectionRange': [CHAIN]},
  }, ['int main(void)', '{', '    one = two;', '}']))

  # On "two", which is what the innermost holds.
  cursor(3, 11)
  call feedkeys("\<Plug>(lsp-selection-expand)", 'x')
  assert_true(t.WaitFor(() => mode() =~# '^v'),
	      'the innermost should be selected')
  assert_equal([3, 9, 3, 11], [line('v'), col('v'), line('.'), col('.')])

  # Out to the statement, then to the block, and no further.
  call feedkeys("\<Plug>(lsp-selection-expand)", 'x')
  assert_equal([3, 5, 3, 14], [line('v'), col('v'), line('.'), col('.')])
  call feedkeys("\<Plug>(lsp-selection-expand)", 'x')
  assert_equal([2, 1, 4, 1], [line('v'), col('v'), line('.'), col('.')])
  call feedkeys("\<Plug>(lsp-selection-expand)", 'x')
  assert_equal([2, 1, 4, 1], [line('v'), col('v'), line('.'), col('.')])
  assert_match('nothing wider', execute('messages'))

  # And back in the way it came.
  call feedkeys("\<Plug>(lsp-selection-shrink)", 'x')
  assert_equal([3, 5, 3, 14], [line('v'), col('v'), line('.'), col('.')])
  call feedkeys("\<Plug>(lsp-selection-shrink)", 'x')
  assert_equal([3, 9, 3, 11], [line('v'), col('v'), line('.'), col('.')])
  # All the way in is where it began: no selection, cursor where it was.
  call feedkeys("\<Plug>(lsp-selection-shrink)", 'x')
  assert_equal('n', mode())
  assert_equal([3, 11], [line('.'), col('.')])

  # The chain is asked for once, however often it is stepped through.
  assert_equal(1, len(t.Sent('textDocument/selectionRange')))
enddef

# A server may answer with a range holding nothing, which clangd does where
# the cursor is outside anything it can name.
def g:Test_a_range_with_nothing_in_it_selects_nothing()
  const EMPTY = {range: {start: {line: 0, character: 3},
			 end: {line: 0, character: 3}}}
  assert_true(t.StartServer({
    capabilities: Offering({selectionRangeProvider: true}),
    replies: {'textDocument/selectionRange': [EMPTY]},
  }, ['int one;', 'int two;']))

  cursor(1, 4)
  call feedkeys("\<Plug>(lsp-selection-expand)", 'x')
  assert_true(t.WaitFor(() =>
		    execute('messages') =~# 'nothing to select'),
	      'the server should be said to have found nothing')
  assert_equal('n', mode())
  assert_equal([1, 4], [line('.'), col('.')])
enddef

def g:Test_a_code_lens_sits_above_its_line()
  g:lsp_client_config.code_lens = true
  defer execute('unlet g:lsp_client_config.code_lens')
  const LENSES = [
    {range: {start: {line: 1, character: 4}, end: {line: 1, character: 10}},
     command: {title: '2 uses', command: 'probe.say', arguments: ['one']}},
    {range: {start: {line: 1, character: 4}, end: {line: 1, character: 10}},
     command: {title: 'run', command: 'probe.run', arguments: []}},
  ]
  assert_true(t.StartServer({
    capabilities: Offering({codeLensProvider: {resolveProvider: false}}),
    replies: {'textDocument/codeLens': LENSES},
  }, ['int main(void)', '    int one;']))

  doautocmd BufEnter
  assert_true(t.WaitFor(() => !prop_list(2)->empty()),
	      'the lens should be shown')

  # Both lenses of the line are one row, lined up with what they are about.
  var shown = prop_list(2)[0]
  assert_equal(['    2 uses | run', 'LspCodeLens'], [shown.text, shown.type])

  # Running one of two asks which, so this picks the second.
  cursor(2, 1)
  LspCodeLensRun
  feedkeys("j\<CR>", 'x')
  assert_true(t.WaitFor(() => !t.Sent('workspace/executeCommand')->empty()),
	      'the command should be run')
  assert_equal('probe.run',
	       t.Sent('workspace/executeCommand')[0].params.command)

  # Turning them off takes the text out of the window.
  LspCodeLens
  assert_equal([], prop_list(2))
enddef

def g:Test_the_rest_of_a_code_lens_is_asked_for()
  g:lsp_client_config.code_lens = true
  defer execute('unlet g:lsp_client_config.code_lens')
  const RANGE = {start: {line: 1, character: 4},
		 end: {line: 1, character: 10}}
  assert_true(t.StartServer({
    capabilities: Offering({codeLensProvider: {resolveProvider: true}}),
    replies: {
      # A place in the file and nothing to say about it yet.
      'textDocument/codeLens': [{range: RANGE, data: 'the rest'}],
      'codeLens/resolve': {range: RANGE,
			   command: {title: '2 uses', command: 'probe.say'}},
    },
  }, ['int main(void)', '    int one;']))

  doautocmd BufEnter
  assert_true(t.WaitFor(() => !prop_list(2)->empty()),
	      'what was asked for should be shown')
  assert_equal('    2 uses', prop_list(2)[0].text)
  assert_equal('the rest', t.Sent('codeLens/resolve')[0].params.data,
	       'the lens goes back as it came')
enddef

def g:Test_the_place_of_a_workspace_symbol_is_asked_for()
  assert_true(t.StartServer({
    capabilities: Offering({workspaceSymbolProvider: {resolveProvider: true}}),
    replies: {
      # The file it is in, but not where in it.
      'workspace/symbol': [{name: 'two', kind: 13, data: 'the rest',
			    location: {uri: 'file://' .. t.SRC}}],
      'workspaceSymbol/resolve': {
	name: 'two', kind: 13,
	location: {uri: 'file://' .. t.SRC,
		   range: {start: {line: 1, character: 4},
			   end: {line: 1, character: 7}}},
      },
    },
  }, ['int one;', 'int two;']))

  LspSymbol two
  assert_true(t.WaitFor(() => !getqflist()->empty()),
	      'the symbol should be listed')
  var items = getqflist()
  assert_equal([2, 5], [items[0].lnum, items[0].col],
	       'the place that was asked for')
  assert_equal('the rest', t.Sent('workspaceSymbol/resolve')[0].params.data,
	       'the symbol goes back as it came')
  cclose
enddef

def g:Test_the_signature_goes_with_the_call_it_describes()
  popup_clear()
  defer popup_clear()
  const SIGNATURE = {signatures: [{label: 'void f(int count)',
				   parameters: [{label: 'int count'}]}]}
  assert_true(t.StartServer({
    capabilities: Offering({signatureHelpProvider:
					      {triggerCharacters: ['(']}}),
    sequence: {'textDocument/signatureHelp':
			      [SIGNATURE, SIGNATURE, {signatures: []}]},
  }, ['    f(x)']))

  # As if the "(" had just been typed, with the cursor right after it.
  cursor(1, 7)
  doautocmd TextChangedI
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'the signature should be shown')
  assert_equal('void f(int count)',
	       getbufline(winbufnr(popup_list()[0]), 1)->get(0, ''))

  # The cursor can be taken out of the call without the text changing, so a
  # move is worth asking about too.
  cursor(1, 5)
  doautocmd CursorMovedI
  assert_true(t.WaitFor(() =>
		    len(t.Sent('textDocument/signatureHelp')) == 2),
	      'a move should be asked about')

  # The call is deleted, so there is nothing left to describe.  The server
  # says as much by answering with no signature at all.
  setline(1, '    ')
  cursor(1, 4)
  doautocmd TextChangedI
  assert_true(t.WaitFor(() => popup_list()->empty()),
	      'the signature should go with the call')
  assert_equal(3, len(t.Sent('textDocument/signatureHelp')))
enddef

def g:Test_the_signature_stands_over_the_call_it_describes()
  popup_clear()
  defer popup_clear()
  assert_true(t.StartServer({
    capabilities: Offering({signatureHelpProvider:
					      {triggerCharacters: ['(']}}),
    replies: {'textDocument/signatureHelp': {signatures: [
		    {label: 'clear_oparg(oparg_T *oap) -> void',
		     parameters: [{label: 'oparg_T *oap'}]}]}},
  }, ['    clear_oparg(x)']))

  # As if the "(" had just been typed, with the cursor right after it.
  cursor(1, 17)
  doautocmd TextChangedI
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'the signature should be shown')
  # The name in the signature over the name of the call, not over the cursor.
  assert_equal(screenpos(win_getid(), 1, 5).col,
	       popup_getpos(popup_list()[0]).core_col)
enddef

def g:Test_inlay_hints_are_put_in_the_window()
  g:lsp_client_config.inlay_hint = true
  defer execute('unlet g:lsp_client_config.inlay_hint')
  # A parameter name before the argument, and a type after the name.
  const HINTS = [
    {position: {line: 0, character: 8}, label: 'count:', kind: 2,
     paddingRight: true},
    {position: {line: 1, character: 5}, label: [{value: ': int'}], kind: 1},
  ]
  assert_true(t.StartServer({
    capabilities: Offering({inlayHintProvider: true}),
    replies: {'textDocument/inlayHint': HINTS},
  }, ['    f(10);', 'var x = 1;']))

  doautocmd WinScrolled
  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the hint should be shown')

  var first = prop_list(1)[0]
  assert_equal(['count: ', 'LspInlayParameter'],
	       [first.text, first.type])
  var second = prop_list(2)[0]
  assert_equal([': int', 'LspInlayType'], [second.text, second.type])

  # What the server was asked about is the part on screen.
  var asked = t.Sent('textDocument/inlayHint')[0].params.range
  assert_equal(0, asked.start.line)
  assert_equal(1, asked.end.line)
enddef

def g:Test_inlay_hints_stay_away_unless_asked_for()
  assert_true(t.StartServer({
    capabilities: Offering({inlayHintProvider: true}),
    replies: {'textDocument/inlayHint': [
      {position: {line: 0, character: 8}, label: 'count:', kind: 2}]},
  }, ['    f(10);']))

  doautocmd WinScrolled
  sleep 200m
  assert_true(t.Sent('textDocument/inlayHint')->empty(),
	      'nothing should be asked for while the option is off')
  assert_equal([], prop_list(1))
enddef

def g:Test_the_rest_of_an_inlay_hint_is_asked_for()
  g:lsp_client_config.inlay_hint = true
  defer execute('unlet g:lsp_client_config.inlay_hint')
  defer popup_clear()
  const HINT = {position: {line: 1, character: 9}, label: ': int', kind: 1,
		data: 'the rest'}
  assert_true(t.StartServer({
    capabilities: Offering({inlayHintProvider: {resolveProvider: true}}),
    replies: {
      'textDocument/inlayHint': [HINT],
      # What the hint carries besides the text it shows.
      'inlayHint/resolve': extend(HINT->copy(), {
	tooltip: 'the type it works out to',
	textEdits: [{newText: ': int',
		     range: {start: {line: 1, character: 9},
			     end: {line: 1, character: 9}}}],
      }),
    },
  }, ['int main(void)', '    var x = 1;']))

  doautocmd WinScrolled
  assert_true(t.WaitFor(() => !prop_list(2)->empty()),
	      'the hint should be shown')

  # Nothing is asked for until the hint is acted on.
  assert_equal([], t.Sent('inlayHint/resolve'))

  cursor(2, 9)
  LspInlayHintInfo
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'what the hint has to say should be shown')
  assert_equal('the type it works out to',
	       getbufline(winbufnr(popup_list()[0]), 1)->get(0, ''))
  assert_equal('the rest', t.Sent('inlayHint/resolve')[0].params.data,
	       'the hint goes back as it came')

  popup_clear()
  LspInlayHintApply
  assert_true(t.WaitFor(() => getline(2) ==# '    var x: int = 1;'),
	      'the change that goes with the hint should be made')
enddef

def g:Test_inlay_hints_can_be_turned_on_and_off()
  defer execute('unlet! g:lsp_client_config.inlay_hint')
  assert_true(t.StartServer({
    capabilities: Offering({inlayHintProvider: true}),
    replies: {'textDocument/inlayHint': [
      {position: {line: 0, character: 8}, label: 'count:', kind: 2}]},
  }, ['    f(10);']))

  # Off to start with, so nothing is there.
  assert_equal([], prop_list(1))

  LspInlayHint
  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the hints should appear')
  assert_true(g:lsp_client_config.inlay_hint)

  LspInlayHint
  assert_equal([], prop_list(1), 'the hints should be taken away')
  assert_false(g:lsp_client_config.inlay_hint)
enddef

# Five numbers per token, each counted from the one before: line, start,
# length, type, modifiers.
const LEGEND = {tokenTypes: ['type', 'variable', 'function'],
		tokenModifiers: []}
const TOKENS = [0, 0, 3, 0, 0,
		0, 4, 1, 1, 0,
		1, 0, 4, 0, 0,
		0, 5, 1, 2, 0]
const SOURCE = ['int x = 1;', 'void f(void);']

def PaintedOn(lnum: number): list<list<any>>
  return prop_list(lnum)->mapnew((_, p) => [p.col, p.length, p.type])
enddef

def g:Test_the_server_colors_what_it_parsed()
  g:lsp_client_config.semantic_tokens = true
  defer execute('unlet g:lsp_client_config.semantic_tokens')
  assert_true(t.StartServer({
    capabilities: Offering({semanticTokensProvider:
					{legend: LEGEND, full: true}}),
    replies: {'textDocument/semanticTokens/full': {data: TOKENS}},
  }, SOURCE))

  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the text should be colored')
  assert_equal([[1, 3, 'LspSemType'], [5, 1, 'LspSemVariable']],
	       PaintedOn(1))
  assert_equal([[1, 4, 'LspSemType'], [6, 1, 'LspSemFunction']],
	       PaintedOn(2))

  # A change made in Insert mode is asked about too, so what is coming out
  # from under a comment marker does not keep its old colors until <Esc>.
  setline(1, '// int x = 1;')
  doautocmd TextChangedI
  assert_true(t.WaitFor(() =>
		  len(t.Sent('textDocument/semanticTokens/full')) == 2),
	      'an edit in Insert mode should be asked about')
enddef

def g:Test_a_delta_is_folded_into_what_was_there()
  g:lsp_client_config.semantic_tokens = true
  defer execute('unlet g:lsp_client_config.semantic_tokens')
  assert_true(t.StartServer({
    capabilities: Offering({semanticTokensProvider:
				{legend: LEGEND, full: {delta: true}}}),
    replies: {
      'textDocument/semanticTokens/full': {resultId: '1', data: TOKENS},
      # The first token becomes a function, the rest stays as it was.
      'textDocument/semanticTokens/full/delta':
	  {resultId: '2',
	   edits: [{start: 0, deleteCount: 5, data: [0, 0, 3, 2, 0]}]},
    },
  }, SOURCE))

  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the text should be colored')

  setline(1, 'int y = 1;')
  doautocmd TextChanged
  assert_true(t.WaitFor(() =>
		  !t.Sent('textDocument/semanticTokens/full/delta')->empty()),
	      'a change should be asked about with a delta')
  var asked = t.Sent('textDocument/semanticTokens/full/delta')[0]
  assert_equal('1', asked.params.previousResultId)

  assert_true(t.WaitFor(() => PaintedOn(1)[0][2] ==# 'LspSemFunction'),
	      'the delta should reach the buffer')
  assert_equal([[1, 3, 'LspSemFunction'], [5, 1, 'LspSemVariable']],
	       PaintedOn(1))
enddef

def g:Test_a_modifier_takes_over_from_the_token_type()
  g:lsp_client_config.semantic_tokens = true
  defer execute('unlet g:lsp_client_config.semantic_tokens')
  const MODS = {tokenTypes: ['variable', 'function'],
		tokenModifiers: ['declaration', 'readonly', 'deprecated']}
  # A plain variable, a readonly one, and a deprecated function.
  const MARKED = [0, 0, 1, 0, 0,
		  0, 2, 1, 0, 2,
		  0, 2, 1, 1, 4]
  assert_true(t.StartServer({
    capabilities: Offering({semanticTokensProvider:
					{legend: MODS, full: true}}),
    replies: {'textDocument/semanticTokens/full': {data: MARKED}},
  }, ['a b c']))

  assert_true(t.WaitFor(() => len(prop_list(1)) == 3),
	      'every token should be painted')
  assert_equal([[1, 1, 'LspSemVariable'],
		[3, 1, 'LspSemReadonly'],
		[5, 1, 'LspSemDeprecated']], PaintedOn(1))

  # A group for the pair says more than one for the modifier alone, so it is
  # the one that is used.
  highlight link LspSemVariableReadonly Todo
  defer execute('highlight clear LspSemVariableReadonly')
  setline(1, 'a b c ')
  doautocmd TextChanged
  assert_true(t.WaitFor(() => PaintedOn(1)
		    ->copy()
		    ->filter((_, p) => p[2] ==# 'LspSemVariableReadonly')
		    ->len() == 1),
	      'the group for the pair should win')
enddef

def g:Test_the_colors_can_be_turned_on_and_off()
  defer execute('unlet! g:lsp_client_config.semantic_tokens')
  assert_true(t.StartServer({
    capabilities: Offering({semanticTokensProvider:
					{legend: LEGEND, full: true}}),
    replies: {'textDocument/semanticTokens/full': {data: TOKENS}},
  }, SOURCE))

  # Off to start with, so nothing is painted.
  assert_equal([], prop_list(1))

  LspSemanticTokens
  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the colors should appear')
  assert_true(g:lsp_client_config.semantic_tokens)

  LspSemanticTokens
  assert_equal([], prop_list(1), 'the colors should be taken away')
  assert_false(g:lsp_client_config.semantic_tokens)
enddef

def g:Test_only_the_part_on_screen_without_a_full_request()
  g:lsp_client_config.semantic_tokens = true
  defer execute('unlet g:lsp_client_config.semantic_tokens')
  assert_true(t.StartServer({
    capabilities: Offering({semanticTokensProvider:
					{legend: LEGEND, range: true}}),
    replies: {'textDocument/semanticTokens/range': {data: TOKENS}},
  }, SOURCE))

  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the text should be colored')
  assert_true(t.Sent('textDocument/semanticTokens/full')->empty(),
	      'a request the server does not offer should not be sent')
  var asked = t.Sent('textDocument/semanticTokens/range')[0].params.range
  assert_equal(0, asked.start.line)
  assert_equal(1, asked.end.line)
enddef

def g:Test_a_request_that_was_turned_down_is_not_asked_again()
  g:lsp_client_config.semantic_tokens = true
  defer execute('unlet g:lsp_client_config.semantic_tokens')
  # A server can offer the tokens and turn every request for them down.
  assert_true(t.StartServer({
    capabilities: Offering({semanticTokensProvider:
					{legend: LEGEND, full: true}}),
    errors: {'textDocument/semanticTokens/full':
	     {code: -32603, message: 'semantictokens are disabled'}},
  }, SOURCE))

  # The reply is what the message comes from, so the request being on its way
  # is not far enough.
  assert_true(t.WaitFor(() =>
	      execute('messages') =~# 'semantictokens are disabled'),
	      'the turn-down should be reported')

  # Every change after that leaves the server alone.
  setline(1, 'int y = 2;')
  doautocmd TextChanged
  sleep 400m
  assert_equal(1, len(t.Sent('textDocument/semanticTokens/full')))
enddef

def g:Test_the_diagnostics_are_asked_for_when_they_are_not_sent()
  const REPORT = {
    range: {start: {line: 0, character: 4}, end: {line: 0, character: 8}},
    severity: 1,
    message: 'a fault',
  }
  assert_true(t.StartServer({
    capabilities: Offering({diagnosticProvider:
			{identifier: 'test', interFileDependencies: false,
			 workspaceDiagnostics: false}}),
    sequence: {'textDocument/diagnostic': [
      {kind: 'full', resultId: '1', items: [REPORT]},
      {kind: 'unchanged', resultId: '1'},
    ]},
  }, ['int main(void)', '{', '}']))

  assert_true(t.WaitFor(() => !prop_list(1)->empty()),
	      'the report should be shown')
  var first = t.Sent('textDocument/diagnostic')[0].params
  assert_equal('test', first.identifier)
  assert_false(first->has_key('previousResultId'),
	       'there is nothing to hand back the first time')

  # The answer to the second one says nothing changed, so what is on the
  # screen is what was reported before.
  setline(2, '{ ')
  doautocmd TextChanged
  assert_true(t.WaitFor(() =>
		    len(t.Sent('textDocument/diagnostic')) == 2),
	      'a change should be asked about')
  assert_equal('1',
	       t.Sent('textDocument/diagnostic')[1].params.previousResultId)
  assert_false(prop_list(1)->empty(), 'the report should still stand')
enddef

def g:Test_a_watched_file_being_written_is_reported()
  defer popup_clear()
  const HEADER = t.SRC->substitute('\.c$', '.h', '')
  defer delete(HEADER)
  const WATCH = {
    id: 'w1',
    method: 'workspace/didChangeWatchedFiles',
    registerOptions: {watchers: [{globPattern: '**/*.h'}]},
  }
  assert_true(t.StartServer({
    capabilities: Offering({hoverProvider: true, definitionProvider: true}),
    replies: {'textDocument/hover': {contents: 'something'},
	      'textDocument/definition': v:null},
    # The server asks for the watch while answering a hover, and gives it up
    # again while answering a definition.
    ask: {
      'textDocument/hover': [{id: 'reg', method: 'client/registerCapability',
			      params: {registrations: [WATCH]}}],
      'textDocument/definition': [{id: 'unreg',
			      method: 'client/unregisterCapability',
			      params: {unregisterations: [
				  {id: 'w1', method: WATCH.method}]}}],
    },
  }, ['int one;']))

  LspHover
  assert_true(t.WaitFor(() =>
		  t.Trace()->copy()
		    ->filter((_, m) => string(m->get('id', '')) ==# "'reg'")
		    ->len() == 1),
	      'the registration should be answered')

  # This one is not watched, so writing it says nothing.
  write
  execute 'edit ' .. fnameescape(HEADER)
  setline(1, '// a header')
  write
  assert_true(t.WaitFor(() =>
		  !t.Sent('workspace/didChangeWatchedFiles')->empty()),
	      'writing a watched file should be reported')
  var sent = t.Sent('workspace/didChangeWatchedFiles')
  assert_equal(1, len(sent), 'only the watched one should be reported')
  assert_match('Xsrc\.h$', sent[0].params.changes[0].uri)
  assert_equal(1, sent[0].params.changes[0].type, 'the file was created')

  # Once the watch is given up there is nothing left to report.
  LspDefinition
  assert_true(t.WaitFor(() => !t.Sent('textDocument/definition')->empty()),
	      'the server should be asked')
  sleep 100m
  write
  sleep 100m
  assert_equal(1, len(t.Sent('workspace/didChangeWatchedFiles')),
	       'a watch that was given up should say nothing')
enddef

def g:Test_folds_come_from_the_server()
  defer execute('unlet! g:lsp_client_config.folding')
  const RANGES = [
    {startLine: 0, endLine: 4},
    {startLine: 1, endLine: 2},
  ]
  assert_true(t.StartServer({
    capabilities: Offering({foldingRangeProvider: true}),
    replies: {'textDocument/foldingRange': RANGES},
  }, ['one', 'two', 'three', 'four', 'five']))

  # Off to start with: the buffer keeps whatever folding it had.
  assert_equal('manual', &foldmethod)

  LspFolding
  assert_true(t.WaitFor(() => &foldmethod ==# 'expr'),
	      'folding should be handed over')
  assert_equal('lsp#FoldExpr(v:lnum)', &foldexpr)
  # The inner range sits inside the outer one, so those lines are deeper.
  assert_equal(['1', '2', '2', '1', '1'],
	       range(1, 5)->mapnew((_, l) => lsp#FoldExpr(l)))

  LspFolding
  assert_equal('manual', &foldmethod, 'what was there should come back')
  assert_false(g:lsp_client_config.folding)
enddef

def g:Test_who_calls_this()
  const ITEM = {name: 'callee', kind: 12, uri: 'file://' .. t.SRC,
		range: {start: {line: 0, character: 0},
			end: {line: 0, character: 6}},
		selectionRange: {start: {line: 0, character: 0},
				 end: {line: 0, character: 6}}}
  const CALLS = [{
    from: {name: 'caller', kind: 12, uri: 'file://' .. t.SRC,
	   range: {start: {line: 2, character: 0},
		   end: {line: 2, character: 6}},
	   selectionRange: {start: {line: 2, character: 0},
			    end: {line: 2, character: 6}}},
    fromRanges: [{start: {line: 2, character: 4},
		  end: {line: 2, character: 10}}],
  }]
  assert_true(t.StartServer({
    capabilities: Offering({callHierarchyProvider: true}),
    replies: {'textDocument/prepareCallHierarchy': [ITEM],
	      'callHierarchy/incomingCalls': CALLS},
  }, ['callee();', '', '    callee();']))

  cursor(1, 1)
  LspIncomingCalls
  assert_true(t.WaitFor(() => len(getqflist()) == 1),
	      'the call should be listed')
  var item = getqflist()[0]
  # The place the call is written, named after the function it sits in.
  assert_equal([3, 5, '[Function] caller'],
	       [item.lnum, item.col, item.text])
  cclose

  # What was asked about is what prepare answered with.
  var sent = t.Sent('callHierarchy/incomingCalls')[0].params
  assert_equal('callee', sent.item.name)
enddef

def g:Test_what_this_calls()
  const ITEM = {name: 'caller', kind: 12, uri: 'file://' .. t.SRC,
		range: {start: {line: 0, character: 0},
			end: {line: 0, character: 6}},
		selectionRange: {start: {line: 0, character: 0},
				 end: {line: 0, character: 6}}}
  const CALLS = [{
    to: {name: 'callee', kind: 12, uri: 'file:///elsewhere.c',
	 range: {start: {line: 9, character: 0},
		 end: {line: 9, character: 6}},
	 selectionRange: {start: {line: 9, character: 0},
			  end: {line: 9, character: 6}}},
    fromRanges: [{start: {line: 1, character: 4},
		  end: {line: 1, character: 10}}],
  }]
  assert_true(t.StartServer({
    capabilities: Offering({callHierarchyProvider: true}),
    replies: {'textDocument/prepareCallHierarchy': [ITEM],
	      'callHierarchy/outgoingCalls': CALLS},
  }, ['caller();', '    callee();']))

  cursor(1, 1)
  LspOutgoingCalls
  assert_true(t.WaitFor(() => len(getqflist()) == 1))
  var item = getqflist()[0]
  # An outgoing call is written here, whatever file the callee lives in.
  assert_equal([2, 5, '[Function] callee'],
	       [item.lnum, item.col, item.text])
  assert_match('Xsrc\.c$', bufname(item.bufnr))
  cclose
enddef

def g:Test_what_a_type_is_derived_from()
  const ITEM = {name: 'Derived', kind: 23, uri: 'file://' .. t.SRC,
		range: {start: {line: 2, character: 0},
			end: {line: 2, character: 7}},
		selectionRange: {start: {line: 2, character: 7},
				 end: {line: 2, character: 14}}}
  const SUPER = [{name: 'Middle', kind: 23, uri: 'file://' .. t.SRC,
		  range: {start: {line: 1, character: 0},
			  end: {line: 1, character: 40}},
		  selectionRange: {start: {line: 1, character: 7},
				   end: {line: 1, character: 13}}}]
  assert_true(t.StartServer({
    capabilities: Offering({typeHierarchyProvider: true}),
    replies: {'textDocument/prepareTypeHierarchy': [ITEM],
	      'typeHierarchy/supertypes': SUPER},
  }, ['struct Base {};', 'struct Middle : Base {};',
      'struct Derived : Middle {};']))

  cursor(3, 8)
  LspSuperTypes
  assert_true(t.WaitFor(() => len(getqflist()) == 1),
	      'the type above should be listed')
  var item = getqflist()[0]
  # The name is where one wants to land, not the start of the line.
  assert_equal([2, 8, '[Struct] Middle'], [item.lnum, item.col, item.text])
  cclose

  # What was asked about is what prepare answered with.
  var sent = t.Sent('typeHierarchy/supertypes')[0].params
  assert_equal('Derived', sent.item.name)
enddef

def g:Test_a_part_the_server_turns_down()
  # A server can offer something and still turn down a part of it, as clangd
  # does with outgoing calls.  That should not read like a fault here.
  const ITEM = {name: 'f', kind: 12, uri: 'file://' .. t.SRC,
		range: {start: {line: 0, character: 0},
			end: {line: 0, character: 1}},
		selectionRange: {start: {line: 0, character: 0},
				 end: {line: 0, character: 1}}}
  assert_true(t.StartServer({
    capabilities: Offering({callHierarchyProvider: true}),
    replies: {'textDocument/prepareCallHierarchy': [ITEM]},
    errors: {'callHierarchy/outgoingCalls':
	     {code: -32601, message: 'method not found'}},
  }, ['f();']))

  cursor(1, 1)
  LspOutgoingCalls
  assert_true(t.WaitFor(() =>
	      execute('messages') =~# 'does not answer'),
	      'the turn-down should be reported')
  assert_match('the server does not answer callHierarchy/outgoingCalls',
	       execute('messages'))
enddef

# "ascii" rather than a box-drawing style, so that what is drawn does not
# turn on 'encoding' and 'ambiwidth'.
def g:Test_a_popup_is_drawn_the_way_it_was_asked_for()
  assert_true(t.StartServer({
    capabilities: Offering({hoverProvider: true}),
    replies: {'textDocument/hover': {contents: 'x'}},
  }, ['int x;']))
  defer popup_clear()

  g:lsp_client_config.hover_popup = {
    opt: 'border:ascii,opacity:80',
    highlights: 'PopupBorder:ErrorMsg',
  }
  defer execute('unlet g:lsp_client_config.hover_popup')

  LspHover
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'the server should answer with a popup')
  var opts = popup_getoptions(popup_list()[0])
  assert_equal(['-', '|', '-', '|', '+', '+', '+', '+'], opts.borderchars)
  assert_equal(80, opts.opacity)
  assert_equal('PopupBorder:ErrorMsg', opts.highlights)
enddef

# A popup nothing was said about takes the border 'pumopt' names, and keeps
# the one it has always had where 'pumopt' names none.
def g:Test_a_popup_with_nothing_said_follows_pumopt()
  assert_true(t.StartServer({
    capabilities: Offering({hoverProvider: true}),
    replies: {'textDocument/hover': {contents: 'x'}},
  }, ['int x;']))
  defer popup_clear()
  defer execute('set pumopt=')

  set pumopt=border:ascii
  LspHover
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'the server should answer with a popup')
  assert_equal(['-', '|', '-', '|', '+', '+', '+', '+'],
	       popup_getoptions(popup_list()[0]).borderchars)

  popup_clear()
  set pumopt=
  LspHover
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'and answer a second time')
  var opts = popup_getoptions(popup_list()[0])
  assert_true(opts->has_key('border'),
	      'the border it has always had, where "pumopt" names none')
  assert_false(opts->has_key('borderchars'),
	       'and the characters Vim draws a border with')

  # Only saying so takes it away.
  popup_clear()
  g:lsp_client_config.hover_popup = {opt: ''}
  defer execute('unlet g:lsp_client_config.hover_popup')
  LspHover
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'and answer a third time')
  assert_false(popup_getoptions(popup_list()[0])->has_key('border'),
	       'no border where the popup was asked for without one')
enddef

def g:Test_a_popup_asked_for_in_a_way_that_cannot_be_read()
  # Said as the buffer is taken on, without waiting for the popup itself.
  g:lsp_client_config.signature_popup = {opt: 'popup:round'}
  messages clear
  assert_true(t.StartServer({
    capabilities: Offering({hoverProvider: true}),
    replies: {'textDocument/hover': {contents: 'x'}},
  }, ['int x;']))
  defer popup_clear()
  assert_match('g:lsp_client_config.signature_popup: cannot read "popup:round"',
	       execute('messages'))
  # And kept, since what a server says as it starts washes it away.
  assert_match('g:lsp_client_config.signature_popup: cannot read "popup:round"',
	       execute('LspStatus'))
  # :LspConfigCheck says the same however often it is asked.
  for _ in [1, 2]
    assert_match('g:lsp_client_config.signature_popup: cannot read "popup:round"',
		 execute('LspConfigCheck'))
  endfor
  unlet g:lsp_client_config.signature_popup
  assert_match('the configuration is good', execute('LspConfigCheck'))

  # The whole of what is configured, not the popups alone.
  var saved = g:lsp_server_list
  defer execute('g:lsp_server_list = ' .. string(saved))
  g:lsp_client_config.hilight_delay = 100
  defer execute('unlet g:lsp_client_config.hilight_delay')
  g:lsp_client_config.omnifunc = 'yes'
  defer execute('g:lsp_client_config.omnifunc = true')
  g:lsp_server_list = [{name: 1, filetypes: []}]
  var said = execute('LspConfigCheck')
  assert_match('has no such key as "hilight_delay"', said)
  assert_match('"omnifunc" takes true or false', said)
  assert_match('g:lsp_server_list\[0\]: has no "cmd"', said)
  assert_match('g:lsp_server_list\[0\]: "name" takes a String', said)
  assert_match('g:lsp_server_list\[0\]: "filetypes" is empty', said)

  # "popup:" is no key of 'pumopt' and "height:" is one a popup has no use
  # for; both are said so, and the rest of the string is read all the same.
  messages clear
  g:lsp_client_config.hover_popup = {opt: 'popup:round,height:9,opacity:60'}
  defer execute('unlet g:lsp_client_config.hover_popup')
  LspHover
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'the server should answer with a popup')
  assert_match('cannot read "popup:round"', execute('messages'))
  assert_match('"height:9" is for the completion menu alone',
	       execute('messages'))
  assert_equal(60, popup_getoptions(popup_list()[0]).opacity)

  # The same keys in 'pumopt' are the menu's own, so borrowing them says
  # nothing.
  popup_clear()
  unlet g:lsp_client_config.hover_popup
  messages clear
  set pumopt=height:9,margin,border:ascii
  defer execute('set pumopt=')
  LspHover
  assert_true(t.WaitFor(() => !popup_list()->empty()),
	      'and answer a second time')
  assert_notmatch('height', execute('messages'))
  assert_notmatch('margin', execute('messages'))
enddef

def g:Test_hover_needs_the_server_to_offer_it()
  assert_true(t.StartServer({capabilities: SYNC}, ['int x;']))

  LspHover
  sleep 100m
  assert_true(t.Sent('textDocument/hover')->empty(),
	      'nothing should be asked of a server that cannot answer')
  assert_match('does not offer hover', execute('messages'))
enddef
