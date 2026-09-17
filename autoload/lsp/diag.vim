vim9script

# LSP client for Vim - showing what a server reports about a buffer
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21

import autoload './util.vim'

# LSP numbers the severities from 1 to 4.  Index zero stands for an item that
# arrives without one, which the protocol allows; it is treated as an error.
const SEVERITY = [
  {label: 'Error', sign: 'LspDiagErrorSign', prop: 'LspDiagErrorText',
    qf: 'E', priority: 40},
  {label: 'Error', sign: 'LspDiagErrorSign', prop: 'LspDiagErrorText',
    qf: 'E', priority: 40},
  {label: 'Warning', sign: 'LspDiagWarningSign', prop: 'LspDiagWarningText',
    qf: 'W', priority: 30},
  {label: 'Info', sign: 'LspDiagInfoSign', prop: 'LspDiagInfoText',
    qf: 'I', priority: 20},
  {label: 'Hint', sign: 'LspDiagHintSign', prop: 'LspDiagHintText',
    qf: 'N', priority: 10},
]

const SIGN_GROUP = 'lsp'
const PROP_TYPES = ['LspDiagErrorText', 'LspDiagWarningText',
  'LspDiagInfoText', 'LspDiagHintText']

# What each server reported for a buffer: "<bufnr>" holds one list per
# server, since a buffer may be held by more than one and each of them
# reports the whole of what it found every time.
var diagnostics: dict<dict<list<dict<any>>>> = {}

# How each of those servers counts a position.  The marks are drawn again long
# after the answer arrived, so it is kept alongside.
var encodings: dict<dict<string>> = {}

def Reported(bufnr: number): dict<list<dict<any>>>
  return diagnostics->get(string(bufnr), {})
enddef

# The servers that have reported on a buffer, in a settled order.
def Servers(bufnr: number): list<string>
  return Reported(bufnr)->keys()->sort()
enddef

def EncodingFor(bufnr: number, server: string): string
  return encodings->get(string(bufnr), {})->get(server, 'utf-16')
enddef

# Everything reported for a buffer, whoever reported it.
def AllFor(bufnr: number): list<dict<any>>
  var out: list<dict<any>> = []
  var reported = Reported(bufnr)
  for server in Servers(bufnr)
    out += reported[server]
  endfor
  return out
enddef

var defined = false

def Define()
  if defined
    return
  endif
  defined = true

  highlight default link LspDiagError       ErrorMsg
  highlight default link LspDiagWarning     WarningMsg
  highlight default link LspDiagInfo        Directory
  highlight default link LspDiagHint        Comment
  highlight default link LspDiagErrorText   SpellBad
  highlight default link LspDiagWarningText SpellCap
  highlight default link LspDiagInfoText    SpellRare
  highlight default link LspDiagHintText    SpellLocal

  sign_define([
    {name: 'LspDiagErrorSign', text: 'E>', texthl: 'LspDiagError'},
    {name: 'LspDiagWarningSign', text: 'W>', texthl: 'LspDiagWarning'},
    {name: 'LspDiagInfoSign', text: 'I>', texthl: 'LspDiagInfo'},
    {name: 'LspDiagHintSign', text: 'H>', texthl: 'LspDiagHint'},
  ])
  for name in PROP_TYPES
    if prop_type_get(name)->empty()
      prop_type_add(name, {highlight: name, priority: 10})
    endif
  endfor
enddef

def Kind(item: dict<any>): dict<any>
  var severity = item->get('severity', 0)
  return SEVERITY[severity > 0 && severity < len(SEVERITY) ? severity : 0]
enddef

def StartLine(bufnr: number, server: string, item: dict<any>): number
  return util.PosFromLsp(bufnr, item->get('range', {})->get('start', {}),
    EncodingFor(bufnr, server))[0]
enddef

# Nothing has been drawn before the types are there, and asking to remove a
# type that was never made is an error.
def Erase(bufnr: number)
  if !defined
    return
  endif
  sign_unplace(SIGN_GROUP, {buffer: bufnr})
  prop_remove({types: PROP_TYPES, bufnr: bufnr, all: true})
enddef

# The buffer has to be loaded: an unloaded one has no lines to draw on.
def Draw(bufnr: number)
  Erase(bufnr)
  var reported = Reported(bufnr)
  var signs: list<dict<any>> = []
  for server in Servers(bufnr)
    var encoding = EncodingFor(bufnr, server)
    for item in reported[server]
      var kind = Kind(item)
      var range = item->get('range', {})
      var [lnum, col] = util.PosFromLsp(bufnr, range->get('start', {}),
        encoding)
      var [end_lnum, end_col] = util.PosFromLsp(bufnr, range->get('end', {}),
        encoding)
      signs->add({buffer: bufnr, group: SIGN_GROUP, lnum: lnum,
        name: kind.sign, priority: kind.priority})

      # A zero-width range would not be visible, widen it to one character.
      if end_lnum == lnum && end_col <= col
        end_col = col + 1
      endif
      try
        prop_add(lnum, col, {end_lnum: end_lnum, end_col: end_col,
          bufnr: bufnr, type: kind.prop})
      catch /^Vim\%((\a\+)\)\=:E96[456]:/
        # The buffer moved on since the server looked at it; the next round
        # will line up again.
      endtry
    endfor
  endfor
  if !signs->empty()
    sign_placelist(signs)
  endif
enddef

# What a server reports replaces what it reported before, and leaves what the
# other servers reported where it is.
export def Update(bufnr: number, server: string, items: list<dict<any>>,
    encoding: string)
  Define()
  var key = string(bufnr)
  if !diagnostics->has_key(key)
    diagnostics[key] = {}
    encodings[key] = {}
  endif
  diagnostics[key][server] = items
  encodings[key][server] = encoding
  if bufloaded(bufnr)
    Draw(bufnr)
  endif
enddef

# Completion takes the word it is replacing away, and the text properties on
# it go with the text.  The server has no reason to report the same thing
# twice, so what it last reported is drawn again from here.
export def Redraw(bufnr: number)
  if diagnostics->has_key(string(bufnr)) && bufloaded(bufnr)
    Draw(bufnr)
  endif
enddef

export def Clear(bufnr: number)
  var key = string(bufnr)
  if diagnostics->has_key(key)
    remove(diagnostics, key)
  endif
  if encodings->has_key(key)
    remove(encodings, key)
  endif
  if bufloaded(bufnr)
    Erase(bufnr)
  endif
enddef

export def ForLine(bufnr: number, lnum: number): list<dict<any>>
  var out: list<dict<any>> = []
  var reported = Reported(bufnr)
  for server in Servers(bufnr)
    out += reported[server]->copy()
      ->filter((_, item) => StartLine(bufnr, server, item) == lnum)
  endfor
  return out
enddef

# A code action request carries these, so the server knows which reports it is
# being asked to act on.
# Only what the server being asked reported: another one's reports mean
# nothing to it.
export def ForRange(bufnr: number, server: string, first: number,
    last: number): list<dict<any>>
  return Reported(bufnr)->get(server, [])
    ->copy()
    ->filter((_, item) => {
      var range = item->get('range', {})
      var from = range->get('start', {})->get('line', 0) + 1
      var to = range->get('end', {})->get('line', 0) + 1
      return from <= last && to >= first
    })
enddef

def Truncate(s: string, width: number): string
  if strdisplaywidth(s) <= width
    return s
  endif
  var out = ''
  for c in s->split('\zs')
    if strdisplaywidth(out .. c) > width - 1
      break
    endif
    out ..= c
  endfor
  return out .. '>'
enddef

# Show the first diagnostic on the cursor line.  A line without one is left
# alone rather than cleared, so this does not wipe other messages.
export def EchoAtCursor()
  var items = ForLine(bufnr('%'), line('.'))
  if items->empty()
    return
  endif
  var item = items[0]
  var text = printf('%s: %s', Kind(item).label,
    item->get('message', '')->substitute('\n', ' ', 'g'))
  echo Truncate(text, v:echospace)
enddef

# A report may point at other places that explain it, such as where a name was
# declared before.  Those follow it in the list, indented.
def RelatedEntries(bufnr: number, item: dict<any>,
    encoding: string): list<dict<any>>
  var out: list<dict<any>> = []
  for related in item->get('relatedInformation', [])
    if type(related) != v:t_dict
      continue
    endif
    var loc = related->get('location', {})
    var path = util.UriToPath(loc->get('uri', ''))
    if path->empty()
      continue
    endif
    var start = loc->get('range', {})->get('start', {})
    var lnum = start->get('line', 0) + 1
    var line = util.FileLines(path)->get(lnum - 1, '')
    out->add({
      filename: path,
      lnum: lnum,
      col: util.ColFromLsp(line, start->get('character', 0), encoding),
      text: '  ' .. related->get('message', '')->substitute('\n', ' ', 'g'),
    })
  endfor
  return out
enddef

# What |setqflist()| and |setloclist()| take for a file, whether or not there
# is a buffer for it: one without has no lines to count a character offset
# in, so the column is the one the protocol gives.
export def Entries(path: string, items: list<any>,
    encoding: string): list<dict<any>>
  var bufnr = bufnr(util.OpenName(path))
  var entries: list<dict<any>> = []
  for item in items
    if type(item) != v:t_dict
      continue
    endif
    var start = item->get('range', {})->get('start', {})
    var lnum = start->get('line', 0) + 1
    var col = start->get('character', 0) + 1
    if bufnr > 0 && bufloaded(bufnr)
      [lnum, col] = util.PosFromLsp(bufnr, start, encoding)
    endif
    var source = item->get('source', '')
    entries->add({
      filename: path,
      lnum: lnum,
      col: col,
      type: Kind(item).qf,
      text: (source->empty() ? '' : '[' .. source .. '] ')
        .. item->get('message', '')->substitute('\n', ' ', 'g'),
    })
    if bufnr > 0
      entries += RelatedEntries(bufnr, item, encoding)
    endif
  endfor
  return entries
enddef

export def ToLocList(bufnr: number)
  var reported = Reported(bufnr)
  var entries: list<dict<any>> = []
  for server in Servers(bufnr)
    entries += Entries(bufname(bufnr), reported[server],
      EncodingFor(bufnr, server))
  endfor
  if entries->empty()
    echo 'lsp: the server reported nothing for this buffer'
    return
  endif
  setloclist(0, [], ' ', {title: 'LSP diagnostics', items: entries,
    quickfixtextfunc: util.ListText})
  lopen
enddef

export def Count(bufnr: number): number
  return len(AllFor(bufnr))
enddef

# What one server reported, which is what |:LspStatus| shows against it.
export def CountFor(bufnr: number, server: string): number
  return len(Reported(bufnr)->get(server, []))
enddef

# test/run sets this to have every :def compiled as the script is read.
if $LSP_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
