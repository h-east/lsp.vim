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

# What each buffer was last told about, keyed by buffer number as a string.
var diagnostics: dict<list<dict<any>>> = {}

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

def StartLine(bufnr: number, item: dict<any>): number
  return util.PosFromLsp(bufnr, item->get('range', {})->get('start', {}))[0]
enddef

def Erase(bufnr: number)
  sign_unplace(SIGN_GROUP, {buffer: bufnr})
  prop_remove({types: PROP_TYPES, bufnr: bufnr, all: true})
enddef

# Draw the signs and the highlights for what the buffer currently holds.  The
# buffer has to be loaded: an unloaded one has no lines to put them on.
def Draw(bufnr: number)
  Erase(bufnr)
  var items = diagnostics->get(string(bufnr), [])
  if items->empty()
    return
  endif

  var signs: list<dict<any>> = []
  for item in items
    var kind = Kind(item)
    var range = item->get('range', {})
    var [lnum, col] = util.PosFromLsp(bufnr, range->get('start', {}))
    var [end_lnum, end_col] = util.PosFromLsp(bufnr, range->get('end', {}))
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
      # The buffer moved on since the server looked at it.  The next round of
      # diagnostics will line up again, so this one is dropped.
    endtry
  endfor
  sign_placelist(signs)
enddef

export def Update(bufnr: number, items: list<dict<any>>)
  Define()
  diagnostics[string(bufnr)] = items
  if bufloaded(bufnr)
    Draw(bufnr)
  endif
enddef

export def Clear(bufnr: number)
  var key = string(bufnr)
  if diagnostics->has_key(key)
    remove(diagnostics, key)
  endif
  if bufloaded(bufnr)
    Erase(bufnr)
  endif
enddef

export def ForLine(bufnr: number, lnum: number): list<dict<any>>
  return diagnostics->get(string(bufnr), [])
		    ->copy()
		    ->filter((_, item) => StartLine(bufnr, item) == lnum)
enddef

# The reports that touch lines "first" to "last".  A code action request
# carries these, so the server knows which of them it is asked to act on.
export def ForRange(bufnr: number, first: number, last: number): list<dict<any>>
  return diagnostics->get(string(bufnr), [])
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

# Put what is known about a buffer into its location list.
export def ToLocList(bufnr: number)
  var items = diagnostics->get(string(bufnr), [])
  if items->empty()
    echo 'lsp: the server reported nothing for this buffer'
    return
  endif
  var entries: list<dict<any>> = []
  for item in items
    var kind = Kind(item)
    var [lnum, col] = util.PosFromLsp(bufnr,
				item->get('range', {})->get('start', {}))
    var source = item->get('source', '')
    entries->add({
      bufnr: bufnr,
      lnum: lnum,
      col: col,
      type: kind.qf,
      text: (source->empty() ? '' : '[' .. source .. '] ')
	    .. item->get('message', '')->substitute('\n', ' ', 'g'),
    })
  endfor
  setloclist(0, [], ' ', {title: 'LSP diagnostics', items: entries})
  lopen
enddef

export def Count(bufnr: number): number
  return len(diagnostics->get(string(bufnr), []))
enddef

# vim: sw=2 sts=2 et
