vim9script

# LSP client for Vim - server registry, document synchronisation, features
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21

import autoload './lsp/client.vim' as lspclient
import autoload './lsp/diag.vim'
import autoload './lsp/fold.vim'
import autoload './lsp/hl.vim'
import autoload './lsp/inlay.vim'
import autoload './lsp/lens.vim'
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

# What can be asked for in g:lsp_client_config, and what it is when it is not.
const DEFAULTS = {
  omnifunc: true,
  completion_timeout: 2000,
  document_highlight: true,
  highlight_delay: 300,
  signature_help: true,
  inlay_hint: false,
  code_lens: false,
  folding: false,
}

def Setting(name: string): any
  return get(g:, 'lsp_client_config', {})->get(name, DEFAULTS[name])
enddef

def SetSetting(name: string, value: any)
  if !exists('g:lsp_client_config')
    g:lsp_client_config = {}
  endif
  g:lsp_client_config[name] = value
enddef

# Keyed by "<name>@<root>": one server per workspace, not one per buffer.
var clients: dict<dict<any>> = {}

var pending_open: dict<list<number>> = {}

def ClientKey(name: string, root: string): string
  return name .. '@' .. root
enddef

def ServerFor(ft: string): dict<any>
  for config in get(g:, 'lsp_server_list', [])
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

# A filetype plugin has usually set 'omnifunc' by now, to a function working
# from tags.  A server knows more, so it takes over and the old value is put
# back when the buffer is detached.
def SetBufferOptions(cl: dict<any>, bufnr: number)
  if !cl.capabilities->has_key('completionProvider')
	|| !Setting('omnifunc')
    return
  endif
  setbufvar(bufnr, 'lsp_omnifunc_save', getbufvar(bufnr, '&omnifunc'))
  setbufvar(bufnr, '&omnifunc', 'lsp#OmniFunc')
enddef

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
  # The first moment there is a server to ask; without this nothing appears
  # until the cursor moves.
  if bufnr == bufnr('%')
    InlayHints()
    CodeLenses()
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

# Either a plain number or inside a Dict.
def SyncKind(cl: dict<any>): number
  var sync = cl.capabilities->get('textDocumentSync', SYNC_FULL)
  if type(sync) == v:t_dict
    return sync->get('change', SYNC_FULL)
  endif
  return type(sync) == v:t_number ? sync : SYNC_FULL
enddef

# A listener change says: replace the lines "lnum" up to but not including
# "end" with "text".  The document as the server has it always ends in a
# newline, so line "end - 1" exists even when "end" is one past the last line.
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

# What a server says about "save" decides whether the text goes along: asking
# for it means it would rather not read the file itself.
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
    # A server may report on a file that is not open here.
    var bufnr = bufnr(util.UriToPath(uri))
    if bufnr > 0
      diag.Update(bufnr, cl.diagnostics[uri])
    endif
  elseif method ==# 'window/showMessage'
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
    # For the record, and there can be a lot of it.
    cl.log->add(params->get('message', ''))
    if len(cl.log) > 200
      remove(cl.log, 0, len(cl.log) - 201)
    endif
  elseif method ==# '$/progress'
    ShowProgress(params)
  endif
enddef

# Per buffer, and only once a buffer really has a server: watching every
# buffer would pull this script in even when no server is ever used.
var global_hooked = false

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
    autocmd CursorMoved <buffer> HighlightLater()
    autocmd InsertEnter <buffer> StopHighlight()
    autocmd TextChanged,BufEnter <buffer> InlayHints()
    autocmd TextChanged,BufEnter <buffer> CodeLenses()
    autocmd TextChanged,BufEnter <buffer> FoldingRanges()
    autocmd TextChangedI,TextChangedP <buffer> OnTextChanged()
    autocmd CursorMovedI <buffer> OnCursorMovedI()
    autocmd InsertLeave <buffer> CloseSignature()
  augroup END
  if !global_hooked
    # WinScrolled matches on the window ID, so it cannot be per buffer.  Both
    # of these do nothing until there is a client to ask.
    augroup lsp_global
      autocmd!
      autocmd VimLeavePre * Stop()
      autocmd WinScrolled * InlayLater()
    augroup END
    global_hooked = true
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
  StopHighlight()
  inlay.Clear(bufnr)
  lens.Clear(bufnr)
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

# The "contents" of a hover reply is a string, a Dict, or a List of either.
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

# Kept and updated rather than made anew, since it stays up while the call is
# being typed.
var signature_popup = 0

# The completion menu is drawn at zindex 100, see |popup-menu|.  A signature
# is asked for while completing, so it has to sit above the menu.
const SIGNATURE_ZINDEX = 101

# Only the answer to the last question asked is still worth showing; see also
# "resolve_seq".
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
    highlight default link LspSignatureActive PmenuSel
    prop_type_add('LspSignatureActive', {highlight: 'LspSignatureActive'})
  endif
enddef

# A parameter's "label" is either a substring of the signature or a pair of
# offsets into it, in UTF-16 units as everywhere else in the protocol.
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

# The signature goes on the side of the cursor the completion menu is not
# using.  "pos" says which corner "line" refers to; without it the popup lands
# above either way.
# The completion menu opens below the cursor when there is room, so the
# signature goes above.  With nothing above -- right after "zt" -- it goes
# under the menu instead, which is the one place left.
#
# screenrow() is not to be trusted from CompleteChanged, where it answers
# about the menu rather than the cursor, so nothing here is worked out again
# later: ClearOfMenu() only needs where the menu is.
# How the signature popup is drawn, and what that costs it in rows and columns
# beyond the text itself: a border all round, and a space either side.
const SIGNATURE_PADDING = [0, 1, 0, 1]	# top, right, bottom, left
# One row for the border above and one below; likewise a column either side.
const BORDER_ROWS = 1 + 1 + SIGNATURE_PADDING[0] + SIGNATURE_PADDING[2]
const BORDER_COLS = 1 + 1 + SIGNATURE_PADDING[1] + SIGNATURE_PADDING[3]

# The screen row the cursor was on when the signature was asked for.
# screenrow() answers about the menu rather than the cursor when called from
# CompleteChanged, so it is read once, here, and remembered.
var signature_row = 0

# Where the signature fits without covering the cursor line or the menu.
# Above the cursor is tried first, since that is where a call being typed is
# read from.  Empty when neither side has room.
def ClearOfMenu(pum: dict<any>, need: number): dict<any>
  var last = &lines - &cmdheight
  var row = signature_row
  # The rows the menu covers.  pum_getpos() counts them from zero and
  # everything here counts from one; zero stands for "no menu".
  var mtop = pum->empty() ? 0 : pum.row + 1
  var mbot = pum->empty() ? 0 : pum.row + pum.height

  # Above: rows 1 to "bottom", which stops short of the menu when it is up
  # there too.
  var bottom = mbot > 0 && mbot < row ? mtop - 1 : row - 1
  if bottom >= need
    return {line: bottom, col: 'cursor', pos: 'botleft',
	    maxheight: bottom - BORDER_ROWS}
  endif
  # Below: "top" to the last row, starting past the menu when it is there.
  var top = mtop > row ? mbot + 1 : row + 1
  if last - top + 1 >= need
    return {line: top, col: 'cursor', pos: 'topleft',
	    maxheight: last - top + 1 - BORDER_ROWS}
  endif
  return {}
enddef

# How tall the popup will be: the text wrapped at the width it gets, plus the
# border.
def SignatureRows(text: string): number
  var width = SignatureWidth()
  return (strdisplaywidth(text) + width - 1) / width + BORDER_ROWS
enddef

def SignatureWidth(): number
  # Never nothing, however narrow the window is.
  return max([1, &columns - BORDER_COLS])
enddef

# Above or below the cursor, with the room that side has.
def Side(up: bool, above: number, below: number): dict<any>
  return up
      ? {line: 'cursor-1', col: 'cursor', pos: 'botleft',
	 maxheight: max([1, above - BORDER_ROWS])}
      : {line: 'cursor+1', col: 'cursor', pos: 'topleft',
	 maxheight: max([1, below - BORDER_ROWS])}
enddef

def SignatureWhere(text: string): dict<any>
  signature_row = screenrow()
  var need = SignatureRows(text)
  var above = signature_row - 1
  var below = &lines - &cmdheight - signature_row

  var pum = pum_getpos()
  if !pum->empty()
    var clear = ClearOfMenu(pum, need)
    if !clear->empty()
      return clear
    endif
    # The menu leaves room for none of it.  Part of it beats none while the
    # call is being typed, and MoveSignature() takes it away once the menu is
    # touched.
  endif
  # Above when the whole of it fits there, below when it fits there instead,
  # and the roomier side when neither does.  Where the menu will open is not
  # worth guessing at; MoveSignature() moves out of its way once it is up.
  return Side(above >= need || (below < need && above >= below), above, below)
enddef

# The menu may open after the signature is up.  Moving out of its way needs
# only the menu's own position, so this is safe from CompleteChanged.
def MoveSignature()
  if signature_popup <= 0
    return
  endif
  var pum = pum_getpos()
  if pum->empty()
    return
  endif
  # Always placed again rather than only when it looks like an overlap: the
  # menu has just moved or grown, and where it ends up is what decides.
  var text = getbufline(winbufnr(signature_popup), 1)->get(0, '')
  var where = ClearOfMenu(pum, SignatureRows(text))
  if where->empty()
    # Nowhere left: the menu is the one being typed into.
    CloseSignature()
  else
    popup_move(signature_popup, where)
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

  # A signature may say which parameter is active itself.
  var active = signature->get('activeParameter',
					help->get('activeParameter', -1))
  var range = ActiveRange(signature, active)
  var text: any = label
  if !range->empty()
    DefineSignatureProp()
    text = {text: label, props: [{col: range[0] + 1, length: range[1],
				  type: 'LspSignatureActive'}]}
  endif

  var where = SignatureWhere(label)
  if where->empty()
    CloseSignature()
    return
  endif
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
      maxheight: where.maxheight,
      moved: [0, 0, 0],
      zindex: SIGNATURE_ZINDEX,
      border: [],
      padding: SIGNATURE_PADDING,
      maxwidth: SignatureWidth(),
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

# Asked for after a character the server named as a trigger, "(" and "," for a
# C server, and asked again on every change while the popup is up.  What ends
# the call is the server answering with no signature at all: it does that once
# the cursor is no longer inside one, whether the ")" was typed or the "(" was
# deleted.  TextChangedP is there because this has to work while the menu is
# up.
def OnTextChanged()
  if !Setting('signature_help')
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
  if signature_popup <= 0
    var typed = strpart(getline('.'), 0, col('.') - 1)->slice(-1)
    if index(provider->get('triggerCharacters', []), typed) < 0
      return
    endif
  endif
  var here = [bufnr('%'), line('.'), col('.'), getline('.')]
  if here != signature_asked
    signature_asked = here
    Signature()
  endif
enddef

# The cursor can be taken out of the call without the text changing, and the
# popup is asked not to close on its own so that it lives through an argument
# being typed.
def OnCursorMovedI()
  if signature_popup > 0
    OnTextChanged()
  endif
enddef

# A Location names its file in "uri" and a LocationLink in "targetUri".
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

# Each file is read once however many locations fall in it, since the line is
# what places the column.  A "text" of its own overrides that line.
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

# Four requests have this shape: what comes back is a place to go to.
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

# Edits are in the coordinates of the document before any are applied, so the
# later ones go first.  The protocol forbids them from overlapping.
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

# A range covers whole lines only by accident, so what is before it on its
# first line and after it on its last stays.
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

# Worked out on a copy and put back in one go, so a single undo takes all of
# it back.
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

export def Format(first: number, last: number)
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  var bufnr = bufnr('%')
  # Asking about every line is what the whole buffer request is for; a server
  # may offer only one of the two.
  var whole = first <= 1 && last >= BufLineCount(bufnr)
  var provider = whole ? 'documentFormattingProvider'
		       : 'documentRangeFormattingProvider'
  if !cl.capabilities->has_key(provider)
    util.WarningMsg(whole ? 'the server does not offer formatting'
			  : 'the server does not offer formatting a range')
    return
  endif
  # The reply describes the buffer as it was asked about.
  var tick = getbufvar(bufnr, 'changedtick')
  var params: dict<any> = {
    textDocument: {uri: util.PathToUri(bufname(bufnr))},
    options: {tabSize: &tabstop, insertSpaces: &expandtab ? true : false},
  }
  if !whole
    params.range = {
      start: util.PosToLsp(bufnr, first, 1),
      end: util.PosToLsp(bufnr, last, getline(last)->strlen() + 1),
    }
  endif
  var method = whole ? 'textDocument/formatting'
		     : 'textDocument/rangeFormatting'
  lspclient.Request(cl, method, params, (result: any) => {
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

# A rename reaches files the user never opened.
def LoadedBufnr(path: string): number
  var bufnr = bufadd(path)
  if !bufloaded(bufnr)
    bufload(bufnr)
  endif
  return bufnr
enddef

# Changes come as "documentChanges", which can also ask for files to be
# created, renamed or deleted, or as the older plain "changes".  Only changes
# to the text are understood; anything else gives up rather than applying half.
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

# Returns how many files were touched.  Nothing is written; the buffers are
# left for the user to look at and save.
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

# A reply holds Commands, CodeActions, or a mix.  A Command is run by the
# server; a CodeAction usually carries the edit it stands for.
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
  # The changes come back through "workspace/applyEdit", which is what
  # OnRequest() is there for.
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
    # wait for an answer on the command line.
    var options = MENU_OPTIONS->copy()
    options.callback = (_, idx) => {
      if idx > 0 && idx <= len(actions)
	RunAction(cl, actions[idx - 1])
      endif
    }
    popup_menu(actions->mapnew((_, a) => ActionTitle(a)), options)
  })
enddef

# Only the part of the file on screen.  Off by default: this puts text in the
# window that the file does not hold.
def InlayHints()
  if !Setting('inlay_hint')
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

# Once scrolling has come to rest.  Holding down CTRL-E fires WinScrolled
# every few milliseconds, and the part on screen is only worth asking about
# when it stops moving.  Hints are added above lines that are already drawn,
# so a short wait is not felt.
const INLAY_DELAY = 100

var inlay_timer = -1

def InlayLater()
  if inlay_timer != -1
    timer_stop(inlay_timer)
    inlay_timer = -1
  endif
  if !Setting('inlay_hint')
    return
  endif
  inlay_timer = timer_start(INLAY_DELAY, (_) => InlayHints())
enddef

# 'foldmethod' and 'foldexpr' are likely set to something already, so what was
# there is put back on the way out.
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
  if !Setting('folding')
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
    # about again.
    if bufnr == bufnr('%')
      setbufvar(bufnr, '&foldmethod', 'expr')
    endif
  })
enddef

export def ToggleFolding()
  var on = !Setting('folding')
  SetSetting('folding', on)
  if on
    FoldingRanges()
  else
    for info in getbufinfo({bufloaded: 1})
      UnsetFolding(info.bufnr)
    endfor
  endif
  echo 'lsp: folding ' .. (on ? 'on' : 'off')
enddef

export def FoldExpr(lnum: number): string
  return fold.Expr(lnum)
enddef

export def ToggleInlayHints()
  var on = !Setting('inlay_hint')
  SetSetting('inlay_hint', on)
  if on
    InlayHints()
  else
    # Every buffer, not just this one: they were put there while it was on.
    for info in getbufinfo({bufloaded: 1})
      inlay.Clear(info.bufnr)
    endfor
  endif
  echo 'lsp: inlay hints ' .. (on ? 'on' : 'off')
enddef

# What the server has to say about a line, shown above it.  Off by default:
# this puts text in the window that the file does not hold.
def CodeLenses()
  if !Setting('code_lens')
    return
  endif
  var cl = BufClient(bufnr('%'))
  if cl->empty() || !cl.initialized
	|| !cl.capabilities->has_key('codeLensProvider')
    return
  endif
  var bufnr = bufnr('%')
  lspclient.Request(cl, 'textDocument/codeLens',
      {textDocument: {uri: util.PathToUri(bufname(bufnr))}}, (result: any) => {
    if bufnr != bufnr('%')
      return
    endif
    lens.Update(bufnr, type(result) == v:t_list ? result : [])
  })
enddef

export def ToggleCodeLens()
  var on = !Setting('code_lens')
  SetSetting('code_lens', on)
  if on
    CodeLenses()
  else
    # Every buffer, not just this one: they were put there while it was on.
    for info in getbufinfo({bufloaded: 1})
      lens.Clear(info.bufnr)
    endfor
  endif
  echo 'lsp: code lens ' .. (on ? 'on' : 'off')
enddef

# A lens carries the command it stands for, so running it is running that.
export def RunCodeLens()
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  var found = lens.ForLine(bufnr('%'), line('.'))
  if found->empty()
    util.WarningMsg('there is nothing on this line')
    return
  endif
  if len(found) == 1
    RunAction(cl, found[0])
    return
  endif
  var options = MENU_OPTIONS->copy()
  options.title = ' code lens '
  options.callback = (_, idx) => {
    if idx > 0 && idx <= len(found)
      RunAction(cl, found[idx - 1])
    endif
  }
  popup_menu(found->mapnew((_, l) =>
		    l->get('command', {})->get('title', '')), options)
enddef

# Once the cursor has come to rest.  A timer of this plugin decides when that
# is, rather than 'updatetime': that one also drives the swap file, so it is
# not free to be set to what suits marking a symbol.
var highlight_timer = -1

def StopHighlight()
  if highlight_timer != -1
    timer_stop(highlight_timer)
    highlight_timer = -1
  endif
enddef

def HighlightLater()
  StopHighlight()
  if !Setting('document_highlight')
    return
  endif
  highlight_timer = timer_start(Setting('highlight_delay'),
				(_) => HighlightSymbol())
enddef

def HighlightSymbol()
  if !Setting('document_highlight')
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
	# The answer is about where the cursor was.
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
  # The declaration is a mention as well, so it belongs in the list.
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

# A SymbolInformation carries its place in "location"; a WorkspaceSymbol may
# give only the file.
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

# A SymbolKind is a number from 1 to 26, named the way the protocol names it.
#                    1         2         3         4         5         6
const SYMBOL_KINDS = ['File', 'Module', 'Namespace', 'Package', 'Class',
    'Method', 'Property', 'Field', 'Constructor', 'Enum', 'Interface',
    'Function', 'Variable', 'Constant', 'String', 'Number', 'Boolean',
    'Array', 'Object', 'Key', 'Null', 'EnumMember', 'Struct', 'Event',
    'Operator', 'TypeParameter']

# Worth more than the line the symbol sits on.
def SymbolText(sym: dict<any>): string
  var kind = sym->get('kind', 0)
  var name = kind >= 1 && kind <= len(SYMBOL_KINDS)
					      ? SYMBOL_KINDS[kind - 1] : ''
  var container = sym->get('containerName', '')
  return (name->empty() ? '' : '[' .. name .. '] ')
	 .. (container->empty() ? '' : container .. '::')
	 .. sym->get('name', '')
enddef

# A reply about one file is a flat list of SymbolInformation or a tree of
# DocumentSymbol.  Both end up as one list, the depth showing as indent.
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

# What comes back holds the function at the other end and the places the call
# is written.  Those places are what one wants to go to, named after the
# function they sit in.
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

# An item names a type and says where it is written; the name is the place
# worth going to.
def TypeLocations(types: any): list<dict<any>>
  var locs: list<dict<any>> = []
  for item in (type(types) == v:t_list ? types : [])
    if type(item) != v:t_dict
      continue
    endif
    var range = item->get('selectionRange', item->get('range', {}))
    if type(range) == v:t_dict && !range->empty()
      locs->add({uri: item->get('uri', ''), range: range,
		 text: SymbolText(item)})
    endif
  endfor
  return locs
enddef

# One step at a time: what comes back are the types directly above or below
# the one asked about, so a further step means asking again from there.
def TypeHierarchy(up: bool)
  var cl = ReadyClient()
  if cl->empty()
    return
  endif
  if !cl.capabilities->has_key('typeHierarchyProvider')
    util.WarningMsg('the server does not offer a type hierarchy')
    return
  endif
  lspclient.Request(cl, 'textDocument/prepareTypeHierarchy', CursorParams(),
      (result: any) => {
    var items = type(result) == v:t_list ? result : []
    if items->empty() || type(items[0]) != v:t_dict
      util.WarningMsg('there is no type hierarchy here')
      return
    endif
    var what = up ? 'supertypes' : 'subtypes'
    lspclient.Request(cl, 'typeHierarchy/' .. what, {item: items[0]},
		      (types: any) => {
      var qf = LocationItems(TypeLocations(types))
      if qf->empty()
	util.WarningMsg(up ? 'nothing is above this one'
			   : 'nothing is below this one')
	return
      endif
      setqflist([], ' ', {title: 'LSP ' .. what .. ': '
			  .. items[0]->get('name', ''), items: qf})
      copen
    })
  })
enddef

export def SuperTypes()
  TypeHierarchy(true)
enddef

export def SubTypes()
  TypeHierarchy(false)
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
  # An empty query means "everything" to the protocol.
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

# A CompletionItemKind is a number from 1 to 25 and "kind" is a single letter,
# so the letters are indexed by that number.
#                     1234567890123456789012345
const KIND_LETTERS = ' tfffmvcimpuvekSCFrDEdsVoT'

def ItemKind(item: dict<any>): string
  var kind = item->get('kind', 0)
  return kind > 0 && kind < strlen(KIND_LETTERS) ? KIND_LETTERS[kind] : ''
enddef

# Omni completion can only replace the word before the cursor, so only the
# "newText" of a "textEdit" is taken.  Snippet placeholders cannot be
# expanded, for those the label is the honest answer.
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

# The whole item is kept in "user_data" for "completionItem/resolve", which
# needs back the item it produced.
def ToCompleteItem(item: dict<any>): dict<any>
  return {
    word: ItemWord(item),
    # A server may pad the label; clangd puts a space where a return type
    # would go, which shifts every entry in the menu.
    abbr: item->get('label', '')->trim(),
    kind: ItemKind(item),
    menu: item->get('detail', '')->substitute("\n", ' ', 'g'),
    info: ItemInfo(item),
    dup: 1,
    user_data: item,
  }
enddef

# The server is given the position and not the word, so the word still has to
# be honoured here.
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
    # For FixWiderEdit(), once the item is taken.
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
  var timeout = Setting('completion_timeout')
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

# A server may leave the documentation out and only produce it for the item
# actually looked at.  That takes a round trip, so the info popup is filled in
# as the answers arrive; see |complete-popuphidden|.  The counter is bumped on
# every selection change, to drop a reply for an item no longer selected.
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

  # Shown at once, so the popup is never empty while the round trip is in
  # flight.
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

# Where the running completion started from: the line as it was, the cursor in
# it, and the byte the word begins at.
var started: dict<any> = {}

# Omni completion replaces the word before the cursor and nothing else.  When
# a server wants more than that, "obj->fie" becoming "obj.field" for instance,
# what it asked for is put in place of what completion did.
def FixWiderEdit(item: dict<any>): bool
  var edit = item->get('textEdit', {})
  if started->empty() || type(edit) != v:t_dict || !edit->has_key('range')
	|| line('.') != started.lnum
    return false
  endif
  # Only an edit within the one line lines up with what was replaced.
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
  # Both changes belong to the keystroke that took the item.
  try
    undojoin
  catch
  endtry
  setline(started.lnum, text .. rest)
  cursor(started.lnum, strlen(text) + 1)
  return true
enddef

def OnCompleteDone()
  resolve_seq += 1

  # An item may come with edits elsewhere in the file, usually an include to
  # add.  Omni completion puts in the word and knows nothing of the rest.
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
  # They never overlap what completion touched, so they apply as they are.
  # After the event, to stay out of whatever the completion is still doing.
  var bufnr = bufnr('%')
  timer_start(0, (_) => ApplyTextEdits(bufnr, edits))
enddef

export def Diagnostics()
  # "No server" and "nothing to report" look the same in an empty list.
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
  # A server logs in two places; both belong here, told apart by a heading
  # rather than mixed into one stream.
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

# "workspace/applyEdit" is how a server hands over changes it worked out
# itself; "window/workDoneProgress/create" only asks whether it may report
# progress.  Anything else is turned down by the caller.
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
