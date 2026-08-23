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

def g:Test_hover_needs_the_server_to_offer_it()
  assert_true(t.StartServer({capabilities: SYNC}, ['int x;']))

  LspHover
  sleep 100m
  assert_true(t.Sent('textDocument/hover')->empty(),
	      'nothing should be asked of a server that cannot answer')
  assert_match('does not offer hover', execute('messages'))
enddef
