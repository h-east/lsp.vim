vim9script

# LSP client for Vim - server registry, document synchronisation, features
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21

import autoload './lsp/client.vim' as lspclient
import autoload './lsp/diag.vim'
import autoload './lsp/fold.vim'
import autoload './lsp/hl.vim'
import autoload './lsp/inlay.vim'
import autoload './lsp/util.vim'

# Values of the "textDocumentSync" server capability.
const SYNC_NONE = 0
const SYNC_FULL = 1
const SYNC_INCREMENTAL = 2

# How a hover reply is shown.
const POPUP_OPTIONS = {
  moved: 'any',
  border: [],
  padding: [0, 1, 0, 1],
  maxwidth: 78,
}

# How a list to pick from is shown.  Kept out of the function that uses it
# because a dictionary written inside a lambda block is not accepted there.
const MENU_OPTIONS = {
  title: ' code action ',
  border: [],
  padding: [0, 1, 0, 1],
  maxwidth: 78,
}

# Running servers, keyed by "<name>@<root>" so that one server per workspace
# is started rather than one per buffer.
var clients: dict<dict<any>> = {}

# Buffers waiting for their server to finish initializing.
var pending_open: dict<list<number>> = {}

def ClientKey(name: string, root: string): string
  return name .. '@' .. root
enddef

def ServerFor(ft: string): dict<any>
  for config in get(g:, 'lsp_servers', [])
    if index(config->get('filetypes', []), ft) >= 0
      return config
    endif
  endfor
  return {}
enddef

def BufClient(bufnr: number): dict<any>
  var key = getbufvar(bufnr, 'lsp_client_key', '')
  return clients->get(key, {})
enddef

def BufText(bufnr: number): string
  return getbufline(bufnr, 1, '$')->join("\n") .. "\n"
enddef

# What the server offers is only known once it has answered "initialize", so
# the options that depend on it are set when a buffer is handed over.
#
# A filetype plugin has usually set 'omnifunc' by now, to a function working
# from tags.  A server knows more than tags do, so it takes over, and the old
# value is put back when the buffer is detached.
def SetBufferOptions(cl: dict<any>, bufnr: number)
  if !cl.capabilities->has_key('completionProvider')
	|| !get(g:, 'lsp_set_omnifunc', true)
    return
  endif
  setbufvar(bufnr, 'lsp_omnifunc_save', getbufvar(bufnr, '&omnifunc'))
  setbufvar(bufnr, '&omnifunc', 'lsp#OmniFunc')
enddef

# Feed a buffer to a server that is ready for it.
def DidOpen(cl: dict<any>, bufnr: number)
  var uri = util.PathToUri(bufname(bufnr))
  if cl.documents->has_key(uri)
    return
  endif
  SetBufferOptions(cl, bufnr)
  cl.documents[uri] = {version: 1, bufnr: bufnr}
  lspclient.Notify(cl, 'textDocument/didOpen', {
    textDocument: {
      uri: uri,
      languageId: getbufvar(bufnr, '&filetype'),
      version: 1,
      text: BufText(bufnr),
    },
  })
  # Hints are for what is on screen, and this is the first moment there is a
  # server to ask.  Without this nothing appears until the cursor moves.
  if bufnr == bufnr('%')
    InlayHints()
    FoldingRanges()
  endif
enddef

def SendChange(cl: dict<any>, bufnr: number, changes: list<dict<any>>)
  var uri = util.PathToUri(bufname(bufnr))
  var doc = cl.documents->get(uri, {})
  if doc->empty()
    return
  endif
  doc.version += 1
  lspclient.Notify(cl, 'textDocument/didChange', {
    textDocument: {uri: uri, version: doc.version},
    contentChanges: changes,
  })
enddef

# What a server wants for "textDocument/didChange", either as a plain number
# or inside a Dict.
def SyncKind(cl: dict<any>): number
  var sync = cl.capabilities->get('textDocumentSync', SYNC_FULL)
  if type(sync) == v:t_dict
    return sync->get('change', SYNC_FULL)
  endif
  return type(sync) == v:t_number ? sync : SYNC_FULL
enddef

# A listener change says: replace the lines "lnum" up to but not including
# "end" with "text".  That is a range edit covering whole lines, which is what
# is built here.  The document as the server has it always ends in a newline,
# so line "end - 1" exists even when "end" is one past the last line.
def ChangeToLsp(change: dict<any>): dict<any>
  var text = change->get('text', [])
  return {
    range: {
      start: {line: change.lnum - 1, character: 0},
      end: {line: change.end - 1, character: 0},
    },
    text: text->empty() ? '' : text->join("\n") .. "\n",
  }
enddef

# Vim hands a listener five arguments.  The three in the middle repeat what
# each item of the change list already holds, so they are taken and dropped.
def OnChange(bufnr: number, _: number, _: number, _: number,
	     changes: list<dict<any>>)
  var cl = BufClient(bufnr)
  if cl->empty() || !cl.initialized
    return
  endif
  var kind = SyncKind(cl)
  if kind == SYNC_NONE
    return
  endif
  if kind == SYNC_FULL
    SendChange(cl, bufnr, [{text: BufText(bufnr)}])
    return
  endif
  SendChange(cl, bufnr, changes->mapnew((_, c) => ChangeToLsp(c)))
enddef

# A server that only looks at a file when it is written needs telling.  What
# it says about "save" decides whether the text goes along: asking for it
# means it would rather not read the file itself.
def DidSave(bufnr: number)
  var cl = BufClient(bufnr)
  if cl->empty() || !cl.initialized
    return
  endif
  var uri = util.PathToUri(bufname(bufnr))
  if !cl.documents->has_key(uri)
    return
  endif
  var params: dict<any> = {textDocument: {uri: uri}}
  var sync = cl.capabilities->get('textDocumentSync', {})
  if type(sync) == v:t_dict
    var save = sync->get('save', false)
    if type(save) == v:t_dict && save->get('includeText', false)
      params.text = BufText(bufnr)
    endif
  endif
  lspclient.Notify(cl, 'textDocument/didSave', params)
enddef

def DidClose(bufnr: number)
  var cl = BufClient(bufnr)
  if cl->empty()
    return
  endif
  var uri = util.PathToUri(bufname(bufnr))
  if !cl.documents->has_key(uri)
    return
  endif
  remove(cl.documents, uri)
  lspclient.Notify(cl, 'textDocument/didClose', {textDocument: {uri: uri}})
enddef

def OnReady(cl: dict<any>)
  var key = ClientKey(cl.name, cl.root)
  for bufnr in pending_open->get(key, [])
    if bufexists(bufnr)
      DidOpen(cl, bufnr)
    endif
  endfor
  if pending_open->has_key(key)
    remove(pending_open, key)
  endif
enddef

# The "type" of a window message, from most to least serious.
const MSG_ERROR = 1
const MSG_WARNING = 2

# What a server says it is busy with, kept by the token it named, since only
# the first message of a run carries the title.
var progress_title: dict<string> = {}

def ShowProgress(params: any)
  if type(params) != v:t_dict
    return
  endif
  var token = string(params->get('token', ''))
  var value = params->get('value', {})
  if type(value) != v:t_dict
    return
  endif
  var kind = value->get('kind', '')
  if kind ==# 'end'
    if progress_title->has_key(token)
      remove(progress_title, token)
    endif
    echo ''
    return
  endif
  if kind ==# 'begin'
    progress_title[token] = value->get('title', '')
  endif
  var parts = [progress_title->get(token, '')]
  var message = value->get('message', '')
  if !message->empty()
    parts->add(message)
  endif
  var percentage = value->get('percentage', -1)
  if percentage >= 0
    parts->add(percentage .. '%')
  endif
  echo 'lsp: ' .. parts->filter((_, s) => !s->empty())->join(' ')
enddef

def OnNotify(cl: dict<any>, method: string, params: any)
  if method ==# 'textDocument/publishDiagnostics'
    var uri = params->get('uri', '')
    cl.diagnostics[uri] = params->get('diagnostics', [])
    # A server may report on a file that is not open here, there is nothing to
    # draw on for those.
    var bufnr = bufnr(util.UriToPath(uri))
    if bufnr > 0
      diag.Update(bufnr, cl.diagnostics[uri])
    endif
  elseif method ==# 'window/showMessage'
    # This one is meant for the user to read now.
    var type = params->get('type', 0)
    var message = params->get('message', '')->substitute('\n', ' ', 'g')
    if type == MSG_ERROR
      util.ErrorMsg(message)
    elseif type == MSG_WARNING
      util.WarningMsg(message)
    else
      echomsg 'lsp: ' .. message
    endif
  elseif method ==# 'window/logMessage'
    # This one is for the record, and there can be a lot of it; :LspLog is
    # where someone goes looking.
    cl.log->add(params->get('message', ''))
    if len(cl.log) > 200
      remove(cl.log, 0, len(cl.log) - 201)
    endif
  elseif method ==# '$/progress'
    ShowProgress(params)
  endif
enddef

# Watching every buffer for changes would pull this script in even when no
# server is ever used, so the change and unload events are per buffer and are
# only installed once a buffer really has a server.
var leaving_hooked = false

def HookBuffer()
  b:lsp_listener = listener_add(OnChange, bufnr('%'), {text: true})
  augroup lsp_buf
    autocmd! * <buffer>
    autocmd BufUnload <buffer> Detach(expand('<abuf>')->str2nr())
    autocmd BufWritePost <buffer> DidSave(expand('<abuf>')->str2nr())
    autocmd CompleteChanged <buffer> OnCompleteChanged()
    autocmd CompleteDone <buffer> OnCompleteDone()
    autocmd CursorMoved <buffer> diag.EchoAtCursor()
    autocmd CursorMoved <buffer> hl.Clear(bufnr('%'))
    autocmd CursorHold <buffer> HighlightSymbol()
    autocmd CursorHold,TextChanged,BufEnter <buffer> InlayHints()
    autocmd TextChanged,BufEnter <buffer> FoldingRanges()
    autocmd TextChangedI,TextChangedP <buffer> OnTextChanged()
    autocmd InsertLeave <buffer> CloseSignature()
  augroup END
  if !leaving_hooked
    augroup lsp_leave
      autocmd!
      autocmd VimLeavePre * Stop()
    augroup END
    leaving_hooked = true
  endif
enddef

# Connect the current buffer to the server for its 'filetype', starting the
# server when this is the first buffer for that workspace.
export def Attach()
  var bufnr = bufnr('%')
  if !getbufvar(bufnr, 'lsp_client_key', '')->empty()
    return
  endif
  var name = bufname(bufnr)
  if name->empty() || &buftype != ''
    return
  endif
  var config = ServerFor(&filetype)
  if config->empty()
    return
  endif

  var root = util.FindRoot(name, config->get('rootPatterns', ['.git']))
  var key = ClientKey(config.name, root)
  var cl = clients->get(key, {})
  if cl->empty()
    cl = lspclient.Start(config, root, OnReady)
    if cl->empty()
      return
    endif
    clients[key] = cl
  endif
  b:lsp_client_key = key
  HookBuffer()

  if cl.initialized
    DidOpen(cl, bufnr)
  else
    pending_open[key] = pending_open->get(key, []) + [bufnr]
  endif
enddef

export def Detach(bufnr: number = bufnr('%'))
  var listener = getbufvar(bufnr, 'lsp_listener', 0)
  if listener > 0
    listener_remove(listener)
  endif
  DidClose(bufnr)
  diag.Clear(bufnr)
  hl.Clear(bufnr)
  inlay.Clear(bufnr)
  UnsetFolding(bufnr)
  if bufexists(bufnr)
    var saved = getbufvar(bufnr, 'lsp_omnifunc_save', v:null)
    if type(saved) == v:t_string
      setbufvar(bufnr, '&omnifunc', saved)
      setbufvar(bufnr, 'lsp_omnifunc_save', v:null)
    endif
    setbufvar(bufnr, 'lsp_listener', 0)
    setbufvar(bufnr, 'lsp_client_key', '')
  endif
enddef

export def Stop()
  for cl in clients->values()
    lspclient.Stop(cl)
  endfor
  clients = {}
  pending_open = {}
enddef

export def Status()
  if clients->empty()
    echo 'lsp: no server running'
    return
  endif
  for [key, cl] in clients->items()
    echo printf('%s  %s  %d buffer(s)  %d diagnostic(s) here', key,
	cl.initialized ? 'ready' : 'starting', len(cl.documents),
	diag.Count(bufnr('%')))
  endfor
enddef

# The "contents" of a hover reply may be a plain string, a Dict, or a List of
# either.  Flatten whatever comes in.
def HoverText(contents: any): list<string>
  if type(contents) == v:t_string
    return contents->split("\n")
  endif
  if type(contents) == v:t_list
    var out: list<string> = []
    for item in contents
      out += HoverText(item)
    endfor
    return out
  endif
  if type(contents) == v:t_dict
    return contents->get('value', '')->split("\n")
  endif
  return []
enddef

def ReadyClient(): dict<any>
  var cl = BufClient(bufnr('%'))
  if cl->empty() || !cl.initialized
    util.WarningMsg('no server for this buffer')
    return {}
  endif
  # Pending changes are normally sent just before the screen is updated, which
  # is after this request would go out.  Ask about the buffer the user sees.
  listener_flush(bufnr('%'))
  return cl
enddef

def CursorParams(): dict<any>
  return {
    textDocument: {uri: util.PathToUri(bufname('%'))},
    position: util.CursorPosToLsp(),
  }
enddef

export def Hover()
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('hoverProvider')
    util.WarningMsg('the server does not offer hover')
    return
  endif
  lspclient.Request(cl, 'textDocument/hover', CursorParams(),
      (result: any) => {
	if type(result) != v:t_dict
	  util.WarningMsg('no information')
	  return
	endif
	var lines = HoverText(result->get('contents', ''))
	if lines->empty()
	  util.WarningMsg('no information')
	  return
	endif
	popup_atcursor(lines, POPUP_OPTIONS)
      })
enddef

# The signature popup stays up while the call is being typed, so it is kept
# and updated rather than made anew for every keystroke.
var signature_popup = 0

# The completion menu is drawn at zindex 100, see |popup-menu|.  A signature
# is asked for while completing, so it has to sit above the menu.
const SIGNATURE_ZINDEX = 101

# A reply arrives after the cursor may have moved on.  Only the answer to the
# last question asked is still worth showing; see also "resolve_seq".
var signature_seq = 0

# One edit is seen twice when the completion menu opens right after it: once
# as TextChangedI with the menu hidden and once as TextChangedP with it shown.
# The two events keep separate marks of |b:changedtick| on purpose, so what
# was asked about is remembered here instead.
var signature_asked: list<any> = []

def CloseSignature()
  signature_seq += 1
  signature_asked = []
  if signature_popup > 0
    popup_close(signature_popup)
    signature_popup = 0
  endif
enddef

def DefineSignatureProp()
  if prop_type_get('LspSignatureActive')->empty()
    # Highlight of the parameter the cursor is in.
    highlight default link LspSignatureActive PmenuSel
    prop_type_add('LspSignatureActive', {highlight: 'LspSignatureActive'})
  endif
enddef

# "label" of a parameter is either a substring of the signature or, when the
# server was told this client can take them, a pair of offsets into it.  The
# offsets are in UTF-16 units, the same as everywhere else in the protocol.
def ActiveRange(signature: dict<any>, index: number): list<number>
  var params = signature->get('parameters', [])
  if index < 0 || index >= len(params)
    return []
  endif
  var label = signature->get('label', '')
  var plabel = params[index]->get('label', '')
  if type(plabel) == v:t_list && len(plabel) == 2
    var from = byteidxcomp(label, plabel[0], true)
    var to = byteidxcomp(label, plabel[1], true)
    return from < 0 || to < 0 ? [] : [from, to - from]
  endif
  if type(plabel) == v:t_string && !plabel->empty()
    var from = stridx(label, plabel)
    return from < 0 ? [] : [from, strlen(plabel)]
  endif
  return []
enddef

# The completion menu takes the room on one side of the cursor, so the
# signature goes on the other side and both stay readable.  "pos" says which
# corner "line" refers to, without it the popup lands above either way.
def SignatureWhere(): dict<string>
  var pum = pum_getpos()
  if !pum->empty() && pum.row + 1 < screenrow()
    return {line: 'cursor+1', col: 'cursor', pos: 'topleft'}
  endif
  return {line: 'cursor-1', col: 'cursor', pos: 'botleft'}
enddef

# The menu comes up after the signature was asked for, so the side it leaves
# free is only known once it is there.
def MoveSignature()
  if signature_popup > 0
    popup_move(signature_popup, SignatureWhere())
  endif
enddef

def ShowSignature(help: any)
  if type(help) != v:t_dict
    CloseSignature()
    return
  endif
  var signatures = help->get('signatures', [])
  if signatures->empty()
    CloseSignature()
    return
  endif
  var index = help->get('activeSignature', 0)
  var signature = signatures[index >= 0 && index < len(signatures) ? index : 0]
  var label = signature->get('label', '')
  if label->empty()
    CloseSignature()
    return
  endif

  # A signature may say which parameter is active itself, otherwise the reply
  # says it for the whole set.
  var active = signature->get('activeParameter',
					help->get('activeParameter', -1))
  var range = ActiveRange(signature, active)
  var text: any = label
  if !range->empty()
    DefineSignatureProp()
    text = {text: label, props: [{col: range[0] + 1, length: range[1],
				  type: 'LspSignatureActive'}]}
  endif

  var where = SignatureWhere()
  if signature_popup > 0 && popup_getpos(signature_popup)->empty()
    signature_popup = 0
  endif
  if signature_popup > 0
    popup_settext(signature_popup, [text])
    popup_move(signature_popup, where)
  else
    signature_popup = popup_atcursor([text], {
      line: where.line,
      col: where.col,
      pos: where.pos,
      moved: [0, 0, 0],
      zindex: SIGNATURE_ZINDEX,
      border: [],
      padding: [0, 1, 0, 1],
      maxwidth: 78,
    })
  endif
enddef

export def Signature()
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('signatureHelpProvider')
    util.WarningMsg('the server does not offer signature help')
    return
  endif
  signature_seq += 1
  var seq = signature_seq
  lspclient.Request(cl, 'textDocument/signatureHelp', CursorParams(),
      (result: any) => {
	if seq == signature_seq
	  ShowSignature(result)
	endif
      })
enddef

# While typing, ask for the signature after a character the server named as a
# trigger, which for a C server is "(" and ",".  A closing paren ends the
# call, so the popup goes away with it.  This has to work while the completion
# menu is up as well, which is what TextChangedP is for.
def OnTextChanged()
  if !get(g:, 'lsp_signature_help', true)
    return
  endif
  var cl = BufClient(bufnr('%'))
  if cl->empty() || !cl.initialized
    return
  endif
  var provider = cl.capabilities->get('signatureHelpProvider', {})
  if type(provider) != v:t_dict
    return
  endif
  var typed = strpart(getline('.'), 0, col('.') - 1)->slice(-1)
  if typed ==# ')'
    CloseSignature()
  elseif index(provider->get('triggerCharacters', []), typed) >= 0
    var here = [bufnr('%'), line('.'), col('.'), getline('.')]
    if here != signature_asked
      signature_asked = here
      Signature()
    endif
  endif
enddef

# A Location names its file in "uri" and a LocationLink in "targetUri"; the
# link also offers a wider range around the one that is meant.
def LocationUri(loc: dict<any>): string
  return loc->get('uri', loc->get('targetUri', ''))
enddef

def LocationRange(loc: dict<any>): dict<any>
  return loc->get('range', loc->get('targetSelectionRange',
				    loc->get('targetRange', {})))
enddef

# A definition reply is a Location, a list of them, or a list of LocationLink.
def FirstLocation(result: any): dict<any>
  var item = type(result) == v:t_list ? result->get(0, {}) : result
  if type(item) != v:t_dict || item->empty()
    return {}
  endif
  return {uri: LocationUri(item), range: LocationRange(item)}
enddef

# Locations turned into |setqflist()| items.  Each file is read once however
# many locations fall in it, since the line is needed to place the column.
# A "text" of its own overrides the line, for a caller that has something
# better to say than what the file holds there.
def LocationItems(result: any): list<dict<any>>
  var locs = type(result) == v:t_list ? result : [result]
  var lines: dict<list<string>> = {}
  var items: list<dict<any>> = []
  for loc in locs
    if type(loc) != v:t_dict
      continue
    endif
    var uri = LocationUri(loc)
    if uri->empty()
      continue
    endif
    var path = util.UriToPath(uri)
    if !lines->has_key(path)
      lines[path] = util.FileLines(path)
    endif
    var start = LocationRange(loc)->get('start', {})
    var lnum = start->get('line', 0) + 1
    var text = lines[path]->get(lnum - 1, '')
    items->add({
      filename: path,
      lnum: lnum,
      col: util.ColFromLsp(text, start->get('character', 0)),
      text: loc->get('text', text->trim()),
    })
  endfor
  return items
enddef

# Asking where a symbol leads to, which four requests do in the same shape:
# what comes back is a place to go to.  "what" names it in a message.
def JumpTo(method: string, provider: string, what: string)
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key(provider)
    util.WarningMsg('the server does not offer ' .. what)
    return
  endif
  lspclient.Request(cl, method, CursorParams(), (result: any) => {
    var loc = FirstLocation(result)
    if loc->empty()
      util.WarningMsg(what .. ' not found')
      return
    endif
    var path = util.UriToPath(loc.uri)
    if fnamemodify(path, ':p') != fnamemodify(bufname('%'), ':p')
      execute 'edit' fnameescape(path)
    endif
    var [lnum, col] = util.PosFromLsp(bufnr('%'),
			  loc->get('range', {})->get('start', {}))
    cursor(lnum, col)
    normal! zv
  })
enddef

export def Definition()
  JumpTo('textDocument/definition', 'definitionProvider', 'the definition')
enddef

export def Declaration()
  JumpTo('textDocument/declaration', 'declarationProvider',
	 'the declaration')
enddef

export def TypeDefinition()
  JumpTo('textDocument/typeDefinition', 'typeDefinitionProvider',
	 'the type definition')
enddef

export def Implementation()
  JumpTo('textDocument/implementation', 'implementationProvider',
	 'the implementation')
enddef

def BufLineCount(bufnr: number): number
  return getbufinfo(bufnr)->get(0, {})->get('linecount', 0)
enddef

# Edits are expressed in the coordinates of the document as it is before any
# of them are applied, so the later ones are applied first and the earlier
# ones still mean what they said.  The protocol forbids them from overlapping.
def SortedEdits(edits: list<any>): list<any>
  return edits->copy()
      ->filter((_, e) => type(e) == v:t_dict)
      ->sort((a, b) => {
	var pa = a->get('range', {})->get('start', {})
	var pb = b->get('range', {})->get('start', {})
	var la = pa->get('line', 0)
	var lb = pb->get('line', 0)
	return la == lb ? pb->get('character', 0) - pa->get('character', 0)
			: lb - la
      })
enddef

# One edit applied to lines held in a list.  The range covers whole lines only
# by accident, so what is before it on its first line and after it on its last
# stays, and the new text is spliced in between.
def EditLines(lines: list<string>, edit: dict<any>): list<string>
  var range = edit->get('range', {})
  var start = range->get('start', {})
  var last = range->get('end', {})
  var sl = start->get('line', 0)
  if sl < 0 || sl >= len(lines)
    return lines
  endif
  # An end past the last line means "to the end of the document".
  var el = last->get('line', 0)
  if el >= len(lines)
    el = len(lines) - 1
  endif
  if el < sl
    el = sl
  endif
  var head = strpart(lines[sl], 0,
		     util.ColFromLsp(lines[sl], start->get('character', 0)) - 1)
  var tail = strpart(lines[el],
		     util.ColFromLsp(lines[el], last->get('character', 0)) - 1)
  var before = sl > 0 ? lines[0 : sl - 1] : []
  var after = el + 1 < len(lines) ? lines[el + 1 : ] : []
  return before + split(head .. edit->get('newText', '') .. tail, "\n", true)
	 + after
enddef

# The edits are worked out on a copy of the lines and the result is put back,
# so the buffer is written once however many edits there were.
def ApplyTextEdits(bufnr: number, edits: list<any>)
  var lines = getbufline(bufnr, 1, '$')
  for edit in SortedEdits(edits)
    lines = EditLines(lines, edit)
  endfor
  var was = BufLineCount(bufnr)
  setbufline(bufnr, 1, lines)
  if was > len(lines)
    deletebufline(bufnr, len(lines) + 1, was)
  endif
enddef

export def Format()
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('documentFormattingProvider')
    util.WarningMsg('the server does not offer formatting')
    return
  endif
  var bufnr = bufnr('%')
  # The reply is in the coordinates of the buffer as it was asked about, so it
  # is only safe to apply while the buffer has not moved on.
  var tick = getbufvar(bufnr, 'changedtick')
  var params = {
    textDocument: {uri: util.PathToUri(bufname(bufnr))},
    options: {tabSize: &tabstop, insertSpaces: &expandtab ? true : false},
  }
  lspclient.Request(cl, 'textDocument/formatting', params, (result: any) => {
    if type(result) != v:t_list || result->empty()
      util.WarningMsg('nothing to format')
      return
    endif
    if getbufvar(bufnr, 'changedtick') != tick
      util.WarningMsg('the buffer changed while formatting, nothing applied')
      return
    endif
    ApplyTextEdits(bufnr, result)
  })
enddef

# The buffer for a file, loading it when it is not open already.  A rename
# reaches files the user never opened.
def LoadedBufnr(path: string): number
  var bufnr = bufadd(path)
  if !bufloaded(bufnr)
    bufload(bufnr)
  endif
  return bufnr
enddef

# A workspace edit lists its changes per file, either as "documentChanges",
# which can also ask for files to be created, renamed or deleted, or as the
# older plain "changes".  Only changes to the text of a file are understood,
# so anything else makes this give up rather than apply half of the answer.
def WorkspaceEditFiles(edit: dict<any>): list<dict<any>>
  var out: list<dict<any>> = []
  var changes = edit->get('documentChanges', [])
  if type(changes) == v:t_list && !changes->empty()
    for change in changes
      if type(change) != v:t_dict || !change->has_key('edits')
	util.WarningMsg('the server wants to create or remove files, '
			.. 'which is not supported')
	return []
      endif
      out->add({uri: change->get('textDocument', {})->get('uri', ''),
		edits: change.edits})
    endfor
    return out
  endif
  for [uri, edits] in edit->get('changes', {})->items()
    out->add({uri: uri, edits: edits})
  endfor
  return out
enddef

# Applies a workspace edit and returns how many files it touched.  Nothing is
# written; the buffers are left changed for the user to look at and save.
def ApplyWorkspaceEdit(edit: dict<any>): number
  var files = WorkspaceEditFiles(edit)
  var done = 0
  for file in files
    if file.uri->empty() || type(file.edits) != v:t_list || file.edits->empty()
      continue
    endif
    ApplyTextEdits(LoadedBufnr(util.UriToPath(file.uri)), file.edits)
    done += 1
  endfor
  return done
enddef

export def Rename(newname: string)
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('renameProvider')
    util.WarningMsg('the server does not offer rename')
    return
  endif
  var name = newname
  if name->empty()
    name = input('lsp: new name: ', expand('<cword>'))
    if name->empty()
      return
    endif
  endif
  var params = CursorParams()
  params.newName = name
  lspclient.Request(cl, 'textDocument/rename', params, (result: any) => {
    if type(result) != v:t_dict || result->empty()
      util.WarningMsg('the server renamed nothing')
      return
    endif
    var done = ApplyWorkspaceEdit(result)
    if done > 0
      echomsg printf('lsp: renamed to %s in %d file%s, not written yet',
					  name, done, done == 1 ? '' : 's')
    endif
  })
enddef

# A reply holds Commands, CodeActions, or a mix of the two.  A Command is run
# by the server and can only be asked for by name; a CodeAction usually
# carries the edit it stands for and is applied here.
def ActionTitle(action: dict<any>): string
  return action->get('title', action->get('command', ''))
enddef

def RunAction(cl: dict<any>, action: dict<any>)
  if action->has_key('edit')
    var done = ApplyWorkspaceEdit(action.edit)
    if done > 0
      echomsg printf('lsp: %s, %d file%s changed and not written yet',
			  ActionTitle(action), done, done == 1 ? '' : 's')
    endif
    return
  endif
  # A bare Command has the name at the top level, a CodeAction wrapping one
  # keeps it in "command".
  var cmd = action->get('command', {})
  var wrapped = type(cmd) == v:t_dict
  var name = wrapped ? cmd->get('command', '') : cmd
  if type(name) != v:t_string || name->empty()
    util.WarningMsg('the action says neither what to change nor what to run')
    return
  endif
  # The server does the work and hands the changes back through
  # "workspace/applyEdit", which is what OnRequest() is there for.  The reply
  # to this carries nothing worth showing.
  lspclient.Request(cl, 'workspace/executeCommand', {
    command: name,
    arguments: wrapped ? cmd->get('arguments', [])
		       : action->get('arguments', []),
  }, (_) => {
  })
enddef

export def CodeAction(first: number, last: number)
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('codeActionProvider')
    util.WarningMsg('the server does not offer code actions')
    return
  endif
  var bufnr = bufnr('%')
  var params = {
    textDocument: {uri: util.PathToUri(bufname(bufnr))},
    range: {
      start: util.PosToLsp(bufnr, first, 1),
      end: util.PosToLsp(bufnr, last, getline(last)->strlen() + 1),
    },
    context: {diagnostics: diag.ForRange(bufnr, first, last)},
  }
  lspclient.Request(cl, 'textDocument/codeAction', params, (result: any) => {
    var actions = type(result) == v:t_list
		  ? result->copy()->filter((_, a) => type(a) == v:t_dict) : []
    if actions->empty()
      util.WarningMsg('the server offers nothing here')
      return
    endif
    # The reply arrives whenever the server is done, which is no moment to
    # stop and wait for an answer on the command line; a menu can sit there
    # until it is dealt with.
    var options = MENU_OPTIONS->copy()
    options.callback = (_, idx) => {
      if idx > 0 && idx <= len(actions)
	RunAction(cl, actions[idx - 1])
      endif
    }
    popup_menu(actions->mapnew((_, a) => ActionTitle(a)), options)
  })
enddef

# Asking for the names and types to fill in, for the part of the file that is
# on screen.  Off by default: this puts text in the window that the file does
# not hold, which is not something to spring on someone.
def InlayHints()
  if !get(g:, 'lsp_inlay_hint', false)
    return
  endif
  var cl = BufClient(bufnr('%'))
  if cl->empty() || !cl.initialized
	|| !cl.capabilities->has_key('inlayHintProvider')
    return
  endif
  var bufnr = bufnr('%')
  var last = line('w$')
  var params = {
    textDocument: {uri: util.PathToUri(bufname(bufnr))},
    range: {
      start: util.PosToLsp(bufnr, line('w0'), 1),
      end: util.PosToLsp(bufnr, last, getline(last)->strlen() + 1),
    },
  }
  lspclient.Request(cl, 'textDocument/inlayHint', params, (result: any) => {
    if bufnr != bufnr('%')
      return
    endif
    inlay.Update(bufnr, type(result) == v:t_list ? result : [])
  })
enddef

# Folding is 'foldmethod' and 'foldexpr', which the user may well have set to
# something they like, so what was there is put back on the way out.
def SetFolding(bufnr: number)
  if !getbufvar(bufnr, 'lsp_fold_save', {})->empty()
    return
  endif
  setbufvar(bufnr, 'lsp_fold_save', {
    foldmethod: getbufvar(bufnr, '&foldmethod'),
    foldexpr: getbufvar(bufnr, '&foldexpr'),
  })
  setbufvar(bufnr, '&foldexpr', 'lsp#FoldExpr(v:lnum)')
  setbufvar(bufnr, '&foldmethod', 'expr')
enddef

def UnsetFolding(bufnr: number)
  fold.Clear(bufnr)
  if !bufexists(bufnr)
    return
  endif
  var saved = getbufvar(bufnr, 'lsp_fold_save', {})
  if type(saved) != v:t_dict || saved->empty()
    return
  endif
  setbufvar(bufnr, '&foldexpr', saved.foldexpr)
  setbufvar(bufnr, '&foldmethod', saved.foldmethod)
  setbufvar(bufnr, 'lsp_fold_save', {})
enddef

def FoldingRanges()
  if !get(g:, 'lsp_folding', false)
    return
  endif
  var cl = BufClient(bufnr('%'))
  if cl->empty() || !cl.initialized
	|| !cl.capabilities->has_key('foldingRangeProvider')
    return
  endif
  var bufnr = bufnr('%')
  lspclient.Request(cl, 'textDocument/foldingRange',
		    {textDocument: {uri: util.PathToUri(bufname(bufnr))}},
		    (result: any) => {
    fold.Update(bufnr, type(result) == v:t_list ? result : [])
    SetFolding(bufnr)
    # The levels changed under 'foldexpr', which Vim does not know to ask
    # about again on its own.
    if bufnr == bufnr('%')
      setbufvar(bufnr, '&foldmethod', 'expr')
    endif
  })
enddef

export def ToggleFolding()
  g:lsp_folding = !get(g:, 'lsp_folding', false)
  if g:lsp_folding
    FoldingRanges()
  else
    for info in getbufinfo({bufloaded: 1})
      UnsetFolding(info.bufnr)
    endfor
  endif
  echo 'lsp: folding ' .. (g:lsp_folding ? 'on' : 'off')
enddef

export def FoldExpr(lnum: number): string
  return fold.Expr(lnum)
enddef

export def ToggleInlayHints()
  g:lsp_inlay_hint = !get(g:, 'lsp_inlay_hint', false)
  if g:lsp_inlay_hint
    InlayHints()
  else
    # Every buffer, not just this one: they were put there while it was on.
    for info in getbufinfo({bufloaded: 1})
      inlay.Clear(info.bufnr)
    endfor
  endif
  echo 'lsp: inlay hints ' .. (g:lsp_inlay_hint ? 'on' : 'off')
enddef

# Marking where else the symbol under the cursor is used, once the cursor has
# come to rest.  How long that takes is 'updatetime'.
def HighlightSymbol()
  if !get(g:, 'lsp_document_highlight', true)
    return
  endif
  var cl = BufClient(bufnr('%'))
  if cl->empty() || !cl.initialized
	|| !cl.capabilities->has_key('documentHighlightProvider')
    return
  endif
  var at = [bufnr('%'), line('.'), col('.')]
  lspclient.Request(cl, 'textDocument/documentHighlight', CursorParams(),
      (result: any) => {
	# The cursor may have moved on while the answer was on its way, and
	# the answer is about where it was.
	if at != [bufnr('%'), line('.'), col('.')]
	  return
	endif
	hl.Update(at[0], type(result) == v:t_list ? result : [])
      })
enddef

export def References()
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('referencesProvider')
    util.WarningMsg('the server does not offer references')
    return
  endif
  var params = CursorParams()
  # The declaration is a mention of the symbol as well, so it belongs in the
  # list rather than being the one entry that is missing from it.
  params.context = {includeDeclaration: true}
  lspclient.Request(cl, 'textDocument/references', params, (result: any) => {
    var items = LocationItems(result)
    if items->empty()
      util.WarningMsg('no references found')
      return
    endif
    setqflist([], ' ', {title: 'LSP references', items: items})
    copen
  })
enddef

# A SymbolInformation carries its place in "location", a WorkspaceSymbol may
# leave out the range and give only the file.  Either way what comes back is
# turned into something LocationItems() understands.
def SymbolLocation(sym: dict<any>): dict<any>
  var loc = sym->get('location', {})
  if type(loc) != v:t_dict
    return {}
  endif
  var range = loc->get('range', {})
  if range->empty()
    range = {start: {line: 0, character: 0}}
  endif
  return {uri: loc->get('uri', ''), range: range}
enddef

# A SymbolKind is a number from 1 to 26.  The names are what a server would
# have written itself, so the list is shown the way the protocol names it.
#                    1         2         3         4         5         6
const SYMBOL_KINDS = ['File', 'Module', 'Namespace', 'Package', 'Class',
    'Method', 'Property', 'Field', 'Constructor', 'Enum', 'Interface',
    'Function', 'Variable', 'Constant', 'String', 'Number', 'Boolean',
    'Array', 'Object', 'Key', 'Null', 'EnumMember', 'Struct', 'Event',
    'Operator', 'TypeParameter']

# The name the server matched, and what sort of thing it is, say more than the
# line the symbol sits on.
def SymbolText(sym: dict<any>): string
  var kind = sym->get('kind', 0)
  var name = kind >= 1 && kind <= len(SYMBOL_KINDS)
					      ? SYMBOL_KINDS[kind - 1] : ''
  var container = sym->get('containerName', '')
  return (name->empty() ? '' : '[' .. name .. '] ')
	 .. (container->empty() ? '' : container .. '::')
	 .. sym->get('name', '')
enddef

# A reply about one file is either a flat list of SymbolInformation, which
# names its place in "location", or a tree of DocumentSymbol, which carries
# ranges and holds its children.  Both end up as one list, the depth in the
# tree showing as indent.
def FlattenSymbols(syms: any, depth: number, uri: string,
		   out: list<dict<any>>)
  if type(syms) != v:t_list
    return
  endif
  for sym in syms
    if type(sym) != v:t_dict
      continue
    endif
    var where = sym->has_key('location') ? SymbolLocation(sym)
	: {uri: uri, range: sym->get('selectionRange', sym->get('range', {}))}
    if !where->get('uri', '')->empty()
      out->add(extend(where, {text: repeat('  ', depth) .. SymbolText(sym)}))
    endif
    FlattenSymbols(sym->get('children', []), depth + 1, uri, out)
  endfor
enddef

export def Outline()
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('documentSymbolProvider')
    util.WarningMsg('the server does not offer symbols for a file')
    return
  endif
  var uri = util.PathToUri(bufname('%'))
  lspclient.Request(cl, 'textDocument/documentSymbol',
		    {textDocument: {uri: uri}}, (result: any) => {
    var locs: list<dict<any>> = []
    FlattenSymbols(result, 0, uri, locs)
    var items = LocationItems(locs)
    if items->empty()
      util.WarningMsg('the server found no symbols here')
      return
    endif
    setloclist(0, [], ' ', {title: 'LSP symbols in this file', items: items})
    lopen
  })
enddef

# A call is where one function names another.  What comes back holds the
# function at the other end and the places the call is written; those places
# are what one wants to go to, named after the function they sit in.
def CallLocations(calls: any, incoming: bool, here: string): list<dict<any>>
  var locs: list<dict<any>> = []
  for call in (type(calls) == v:t_list ? calls : [])
    if type(call) != v:t_dict
      continue
    endif
    var other = call->get(incoming ? 'from' : 'to', {})
    if type(other) != v:t_dict
      continue
    endif
    # An incoming call is written in the caller's file, an outgoing one in
    # this file.
    var uri = incoming ? other->get('uri', '') : here
    var text = SymbolText(other)
    for range in call->get('fromRanges', [])
      if type(range) == v:t_dict
	locs->add({uri: uri, range: range, text: text})
      endif
    endfor
  endfor
  return locs
enddef

def CallHierarchy(incoming: bool)
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('callHierarchyProvider')
    util.WarningMsg('the server does not offer a call hierarchy')
    return
  endif
  var here = util.PathToUri(bufname('%'))
  # Asking takes two rounds: what is under the cursor, then its calls.
  lspclient.Request(cl, 'textDocument/prepareCallHierarchy', CursorParams(),
      (result: any) => {
    var items = type(result) == v:t_list ? result : []
    if items->empty() || type(items[0]) != v:t_dict
      util.WarningMsg('there is no call hierarchy here')
      return
    endif
    var what = incoming ? 'incoming' : 'outgoing'
    lspclient.Request(cl, 'callHierarchy/' .. what .. 'Calls',
		      {item: items[0]}, (calls: any) => {
      var qf = LocationItems(CallLocations(calls, incoming, here))
      if qf->empty()
	util.WarningMsg(incoming ? 'nothing calls this'
				 : 'this calls nothing')
	return
      endif
      setqflist([], ' ', {title: 'LSP ' .. what .. ' calls: '
			  .. items[0]->get('name', ''), items: qf})
      copen
    })
  })
enddef

export def IncomingCalls()
  CallHierarchy(true)
enddef

export def OutgoingCalls()
  CallHierarchy(false)
enddef

export def Symbol(query: string)
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('workspaceSymbolProvider')
    util.WarningMsg('the server does not offer workspace symbols')
    return
  endif
  # An empty query means "everything" to the protocol, which is not a list to
  # end up with by accident.
  if query->empty()
    util.WarningMsg('a query is needed')
    return
  endif
  lspclient.Request(cl, 'workspace/symbol', {query: query}, (result: any) => {
    var syms = type(result) == v:t_list ? result : []
    var items = LocationItems(syms->mapnew((_, s) =>
			  extend(SymbolLocation(s), {text: SymbolText(s)})))
    if items->empty()
      util.WarningMsg('no symbol matches ' .. query)
      return
    endif
    setqflist([], ' ', {title: 'LSP symbols: ' .. query, items: items})
    copen
  })
enddef

# A CompletionItemKind is a number from 1 to 25 and "kind" in a completion
# item is a single letter, so the letters are indexed by that number.  Index
# zero is never used.
#                     1234567890123456789012345
const KIND_LETTERS = ' tfffmvcimpuvekSCFrDEdsVoT'

def ItemKind(item: dict<any>): string
  var kind = item->get('kind', 0)
  return kind > 0 && kind < strlen(KIND_LETTERS) ? KIND_LETTERS[kind] : ''
enddef

# The text to insert.  A "textEdit" is what the server really wants applied,
# but omni completion can only replace the word before the cursor, so only its
# "newText" is taken.  Snippet placeholders cannot be expanded, for those the
# label is the honest answer.
def ItemWord(item: dict<any>): string
  if item->get('insertTextFormat', 1) == 2
    return item->get('label', '')
  endif
  var edit = item->get('textEdit', {})
  if type(edit) == v:t_dict && edit->has_key('newText')
    return edit.newText
  endif
  return item->get('insertText', item->get('label', ''))
enddef

def ItemInfo(item: dict<any>): string
  var lines = HoverText(item->get('documentation', ''))
  var detail = item->get('detail', '')
  if !detail->empty()
    lines = [detail] + (lines->empty() ? [] : ['']) + lines
  endif
  return lines->join("\n")
enddef

# The whole server item is kept in "user_data" so that it can be handed back
# for "completionItem/resolve", which needs the item it produced.
def ToCompleteItem(item: dict<any>): dict<any>
  return {
    word: ItemWord(item),
    # A server may pad the label, clangd puts a space where a return type
    # would go.  That shifts every entry in the menu by a column.
    abbr: item->get('label', '')->trim(),
    kind: ItemKind(item),
    menu: item->get('detail', '')->substitute("\n", ' ', 'g'),
    info: ItemInfo(item),
    dup: 1,
    user_data: item,
  }
enddef

# The server decides what is relevant, but it is given the position and not
# the word, so the word still has to be honoured here.
def ItemMatches(item: dict<any>, base: string): bool
  if base->empty()
    return true
  endif
  var against = item->get('filterText', item->get('label', ''))
  return against->tolower()->stridx(base->tolower()) == 0
enddef

# 'omnifunc' for a buffer with a server, see |complete-functions|.
export def OmniFunc(findstart: number, base: string): any
  var cl = BufClient(bufnr('%'))
  if cl->empty() || !cl.initialized
    return findstart ? -3 : []
  endif

  if findstart
    # Remembered so that a "textEdit" reaching wider than the word can still
    # be honoured once the item is taken; see FixWiderEdit().
    started = {
      lnum: line('.'),
      line: getline('.'),
      cursor: col('.') - 1,
    }
    var before = strpart(started.line, 0, started.cursor)
    started.word = strlen(before) - strlen(matchstr(before, '\k*$'))
    return started.word
  endif

  listener_flush(bufnr('%'))
  var timeout = get(g:, 'lsp_completion_timeout', 2000)
  var result = lspclient.RequestSync(cl, 'textDocument/completion',
					   CursorParams(), timeout)
  var items: list<any> = []
  if type(result) == v:t_dict
    items = result->get('items', [])
  elseif type(result) == v:t_list
    items = result
  endif
  return items->filter((_, it) => type(it) == v:t_dict
					      && ItemMatches(it, base))
	      ->mapnew((_, it) => ToCompleteItem(it))
enddef

# Servers are allowed to leave the documentation out of a completion item and
# only produce it for the one that is actually looked at.  Asking for it takes
# a round trip, so the info popup is filled in as the answers arrive; see
# |complete-popuphidden|.  Every selection change bumps the counter so a reply
# for an item that is no longer selected can be dropped.
var resolve_seq = 0

def ResolveProvider(cl: dict<any>): bool
  var provider = cl.capabilities->get('completionProvider', {})
  return type(provider) == v:t_dict
			  && provider->get('resolveProvider', false)
enddef

def ShowInfo(text: string)
  var id = popup_findinfo()
  if id <= 0
    return
  endif
  popup_settext(id, text->split("\n"))
  popup_show(id)
enddef

def OnCompleteChanged()
  MoveSignature()
  resolve_seq += 1
  var item = v:event->get('completed_item', {})->get('user_data', {})
  if type(item) != v:t_dict || item->empty()
    return
  endif

  # Whatever came with the item is shown at once, so the popup is never empty
  # while the round trip is in flight.
  var known = ItemInfo(item)
  if !known->empty()
    ShowInfo(known)
  endif

  var cl = BufClient(bufnr('%'))
  if cl->empty() || !cl.initialized || !ResolveProvider(cl)
	|| item->has_key('documentation')
    return
  endif
  var seq = resolve_seq
  lspclient.Request(cl, 'completionItem/resolve', item, (result: any) => {
    if type(result) != v:t_dict || seq != resolve_seq
      return
    endif
    var info = ItemInfo(result)
    if !info->empty()
      ShowInfo(info)
    endif
  })
enddef

# Where the completion that is running started from: the line as it was, the
# cursor in it, and the byte the word being completed begins at.  Empty when
# no completion of ours has been asked for yet.
var started: dict<any> = {}

# Omni completion replaces the word before the cursor and nothing else.  A
# server may want to replace more than that, "obj->fie" becoming "obj.field"
# for instance, and then what it asked for is put in place of what completion
# did.  Returns whether it stepped in.
def FixWiderEdit(item: dict<any>): bool
  var edit = item->get('textEdit', {})
  if started->empty() || type(edit) != v:t_dict || !edit->has_key('range')
	|| line('.') != started.lnum
    return false
  endif
  # Only an edit within the one line can be lined up with what was replaced.
  var range = edit.range
  var first = range->get('start', {})
  var last = range->get('end', {})
  if first->get('line', -1) != started.lnum - 1
	|| last->get('line', -1) != started.lnum - 1
    return false
  endif

  var from = util.ColFromLsp(started.line, first->get('character', 0)) - 1
  var to = util.ColFromLsp(started.line, last->get('character', 0)) - 1
  if from == started.word && to == started.cursor
    # The edit covers the word and no more, which is what was replaced.
    return false
  endif

  var text = strpart(started.line, 0, from) .. edit->get('newText', '')
  var rest = strpart(started.line, to)
  # Both changes belong to the one keystroke that took the item.
  try
    undojoin
  catch
  endtry
  setline(started.lnum, text .. rest)
  cursor(started.lnum, strlen(text) + 1)
  return true
enddef

def OnCompleteDone()
  MoveSignature()
  resolve_seq += 1

  # An item may come with edits elsewhere in the file, an include to add for
  # the name that was just inserted being the usual one.  Omni completion puts
  # in the word and knows nothing of the rest, so it is applied here.
  var item = v:completed_item->get('user_data', {})
  if type(item) != v:t_dict
    started = {}
    return
  endif
  FixWiderEdit(item)
  started = {}

  var edits = item->get('additionalTextEdits', [])
  if type(edits) != v:t_list || edits->empty()
    return
  endif
  # The edits are for the buffer as the server last saw it, and the word that
  # was just inserted is not in that yet.  They never overlap what completion
  # touched, so applying them as they are is safe; doing so after the event
  # keeps this out of whatever the completion is still doing.
  var bufnr = bufnr('%')
  timer_start(0, (_) => ApplyTextEdits(bufnr, edits))
enddef

export def Diagnostics()
  # Tell "no server" apart from "nothing to report", they look the same to
  # someone who just sees an empty list.
  var cl = BufClient(bufnr('%'))
  if cl->empty() || !cl.initialized
    util.WarningMsg('no server for this buffer')
    return
  endif
  diag.ToLocList(bufnr('%'))
enddef

export def Log()
  var cl = BufClient(bufnr('%'))
  if cl->empty()
    util.WarningMsg('no server for this buffer')
    return
  endif
  # A server logs in two places: what it writes to stderr on its own, and what
  # it sends as "window/logMessage".  Both belong here, told apart by a
  # heading rather than mixed into one stream.
  var lines: list<string> = []
  if !cl.log->empty()
    lines += ['--- window/logMessage ---'] + cl.log
  endif
  if !cl.stderr->empty()
    lines += (lines->empty() ? [] : ['']) + ['--- stderr ---'] + cl.stderr
  endif
  if lines->empty()
    echo 'lsp: the server has logged nothing'
    return
  endif
  new
  setline(1, lines)
  setlocal buftype=nofile bufhidden=wipe noswapfile nomodified
enddef

# A server asks for two things.  "workspace/applyEdit" is how it hands over
# changes it worked out itself, which is what a code action it runs on its
# side comes back as.  "window/workDoneProgress/create" only asks whether it
# may report progress under a token, and is answered by saying nothing went
# wrong.  Anything else is turned down by the caller.
def OnRequest(cl: dict<any>, method: string, params: any,
	      Answer: func(any)): bool
  if method ==# 'window/workDoneProgress/create'
    Answer(v:null)
    return true
  endif
  if method !=# 'workspace/applyEdit'
    return false
  endif
  var edit = type(params) == v:t_dict ? params->get('edit', {}) : {}
  if type(edit) != v:t_dict || edit->empty()
    Answer({applied: false, failureReason: 'nothing to apply'})
    return true
  endif
  var done = ApplyWorkspaceEdit(edit)
  if done > 0
    echomsg printf('lsp: the server changed %d file%s, not written yet',
					  done, done == 1 ? '' : 's')
  endif
  Answer({applied: done > 0})
  return true
enddef

lspclient.SetNotifyHandler(OnNotify)
lspclient.SetRequestHandler(OnRequest)

# vim: sw=2 sts=2 et
