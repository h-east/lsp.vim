vim9script
# Tests for the LSP client.  Run them with test/run.

import './helper.vim' as t

# Document sync is all a server has to offer for a buffer to be handed over.
const SYNC: dict<any> = {textDocumentSync: 2}

def Offering(what: dict<any>): dict<any>
  return extend(SYNC->copy(), what)
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
