vim9script

# LSP client for Vim - marking the other places a symbol is used
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21

import './util.vim'

const KIND_TEXT = 1
const KIND_READ = 2
const KIND_WRITE = 3

const TYPES = {
  [KIND_TEXT]: 'LspHighlightText',
  [KIND_READ]: 'LspHighlightRead',
  [KIND_WRITE]: 'LspHighlightWrite',
}

var defined = false

def Define()
  if defined
    return
  endif
  # Being written to is worth telling apart from being read.
  highlight default link LspHighlightText CursorColumn
  highlight default link LspHighlightRead CursorColumn
  highlight default link LspHighlightWrite Visual
  for name in TYPES->values()
    if prop_type_get(name)->empty()
      prop_type_add(name, {highlight: name})
    endif
  endfor
  defined = true
enddef

export def Clear(bufnr: number)
  if !defined || !bufexists(bufnr)
    return
  endif
  prop_remove({bufnr: bufnr, types: TYPES->values(), all: true})
enddef

# What was marked before is dropped, which is how the marks follow the cursor.
export def Update(bufnr: number, items: list<any>)
  Clear(bufnr)
  if items->empty()
    return
  endif
  Define()
  for item in items
    if type(item) != v:t_dict
      continue
    endif
    var range = item->get('range', {})
    var [lnum, col] = util.PosFromLsp(bufnr, range->get('start', {}))
    var [end_lnum, end_col] = util.PosFromLsp(bufnr, range->get('end', {}))
    var kind = item->get('kind', KIND_TEXT)
    try
      prop_add(lnum, col, {
	bufnr: bufnr,
	end_lnum: end_lnum,
	end_col: end_col,
	type: TYPES->get(kind, TYPES[KIND_TEXT]),
      })
    catch /E96[4-6]/
      # The buffer moved on while the answer was on its way; the next one
      # will be about the buffer as it is now.
    endtry
  endfor
enddef

# test/run sets this to have every :def compiled as the script is read.
if $LSP_COMPILE_CHECK != ''
  defcompile
endif

# vim: sw=2 sts=2 et
