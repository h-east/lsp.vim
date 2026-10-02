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

# Where an item is marked: [lnum, col, end_lnum, end_col].
def Span(bufnr: number, encoding: string, item: dict<any>): list<number>
  var range = item->get('range', {})
  var [lnum, col] = util.PosFromLsp(bufnr, range->get('start', {}), encoding)
  var [end_lnum, end_col] = util.PosFromLsp(bufnr, range->get('end', {}),
    encoding)
  # A zero-width range would not be visible, widen it to one character.
  if end_lnum == lnum && end_col <= col
    end_col = col + 1
  endif
  return [lnum, col, end_lnum, end_col]
enddef

def Mark(bufnr: number, item: dict<any>, span: list<number>)
  try
    prop_add(span[0], span[1], {end_lnum: span[2], end_col: span[3],
      bufnr: bufnr, type: Kind(item).prop})
  catch /^Vim\%((\a\+)\)\=:E96[456]:/
    # The buffer moved on since the server looked at it; the next round will
    # line up again.
  endtry
enddef

# The buffer has to be loaded: an unloaded one has no lines to draw on.
# The marks are put again only on the lines where they differ from what is
# there: marks removed all over the buffer have Vim work out the syntax
# highlighting again.  A report over more than one line has them all put
# again.
def Draw(bufnr: number)
  sign_unplace(SIGN_GROUP, {buffer: bufnr})
  var signs: list<dict<any>> = []
  # "<lnum>": [item, span] for each mark wanted on the line.
  var wanted: dict<list<list<any>>> = {}
  var reported = Reported(bufnr)
  for server in Servers(bufnr)
    var encoding = EncodingFor(bufnr, server)
    for item in reported[server]
      var kind = Kind(item)
      var span = Span(bufnr, encoding, item)
      signs->add({buffer: bufnr, group: SIGN_GROUP, lnum: span[0],
        name: kind.sign, priority: kind.priority})
      var key = string(span[0])
      if !wanted->has_key(key)
        wanted[key] = []
      endif
      wanted[key]->add([item, span])
    endfor
  endfor

  var there = prop_list(1, {bufnr: bufnr, end_lnum: -1, types: PROP_TYPES})
  var lines = wanted->keys()
  if there->indexof((_, p) => !p.start || !p.end) >= 0
      || wanted->values()->flattennew(1)
        ->indexof((_, m) => m[1][0] != m[1][2]) >= 0
    prop_remove({types: PROP_TYPES, bufnr: bufnr, all: true})
  else
    # "<lnum>": [col, length, type] of each mark, for comparing.
    var have: dict<list<string>> = {}
    for p in there
      var key = string(p.lnum)
      if !have->has_key(key)
        have[key] = []
      endif
      have[key]->add(string([p.col, p.length, p.type]))
    endfor
    var Want = (key: string) => wanted->get(key, [])->mapnew((_, m) =>
      string([m[1][1], m[1][3] - m[1][1], Kind(m[0]).prop]))->sort()
    lines = (lines + have->keys())->sort()->uniq()
      ->filter((_, key) => Want(key) != have->get(key, [])->sort())
    for key in lines
      prop_remove({types: PROP_TYPES, bufnr: bufnr, all: true}, str2nr(key))
    endfor
  endif
  for key in lines
    for [item, span] in wanted->get(key, [])
      Mark(bufnr, item, span)
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
# twice, so what it last reported is drawn again from here, on line "lnum"
# only: the marks elsewhere have moved along with what was typed since the
# report, and would all be put back where it has them on every move in the
# menu.
export def Redraw(bufnr: number, lnum: number)
  if !diagnostics->has_key(string(bufnr)) || !bufloaded(bufnr)
    return
  endif
  var marks: list<list<any>> = []
  var reported = Reported(bufnr)
  for server in Servers(bufnr)
    var encoding = EncodingFor(bufnr, server)
    for item in reported[server]
      var span = Span(bufnr, encoding, item)
      if span[0] > lnum || span[2] < lnum
        continue
      elseif span[0] != span[2]
        # Drawn again on the line alone, it would be doubled on the others.
        Draw(bufnr)
        return
      endif
      marks->add([item, span])
    endfor
  endfor
  prop_remove({types: PROP_TYPES, bufnr: bufnr, all: true}, lnum)
  for [item, span] in marks
    Mark(bufnr, item, span)
  endfor
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
  echo util.Truncate(text, v:echospace)
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

# Orders diagnostics "a" and "b" by where they start.
def ByStart(a: dict<any>, b: dict<any>): number
  var sa = a->get('range', {})->get('start', {})
  var sb = b->get('range', {})->get('start', {})
  var d = sa->get('line', 0) - sb->get('line', 0)
  return d != 0 ? d : sa->get('character', 0) - sb->get('character', 0)
enddef

# What |setqflist()| and |setloclist()| take for a file, whether or not there
# is a buffer for it: one without has no lines to count a character offset
# in, so the column is the one the protocol gives.  The protocol leaves the
# order of the diagnostics to the server; they are put in the order of the
# lines, each with its related information after it.
export def Entries(path: string, items: list<any>,
    encoding: string): list<dict<any>>
  var bufnr = bufnr(util.OpenName(path))
  var entries: list<dict<any>> = []
  var diags: list<dict<any>> = items->copy()
    ->filter((_, item) => type(item) == v:t_dict)
  for item in diags->sort(ByStart)
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
