vim9script

# LSP client for Vim - the names and types a server fills in for the reader
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 22

import './util.vim'

const KIND_TYPE = 1
const KIND_PARAMETER = 2

const TYPES = {
  [KIND_TYPE]: 'LspInlayType',
  [KIND_PARAMETER]: 'LspInlayParameter',
}

var defined = false

def Define()
  if defined
    return
  endif
  # This is text the file does not hold, so it is kept quiet.
  highlight default link LspInlayType Comment
  highlight default link LspInlayParameter Comment
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

# A label is a string, or the pieces of one a server can report more about.
def LabelText(hint: dict<any>): string
  var label = hint->get('label', '')
  if type(label) == v:t_string
    return label
  endif
  if type(label) != v:t_list
    return ''
  endif
  return label->mapnew((_, part) =>
		    type(part) == v:t_dict ? part->get('value', '') : '')
	      ->join('')
enddef

# What was put in each buffer, so that the hint at the cursor can be found
# again: a hint carries more than the text it shows.
var shown: dict<list<dict<any>>> = {}

export def Forget(bufnr: number)
  var key = string(bufnr)
  if shown->has_key(key)
    remove(shown, key)
  endif
enddef

# The hint on the line nearest to the column, an empty Dictionary when the
# line has none.
export def At(bufnr: number, lnum: number, col: number): dict<any>
  var best: dict<any> = {}
  var best_off = 0
  for item in shown->get(string(bufnr), [])
    if item.lnum != lnum
      continue
    endif
    var off = abs(item.col - col)
    if best->empty() || off < best_off
      best = item.hint
      best_off = off
    endif
  endfor
  return best
enddef

export def Update(bufnr: number, hints: list<any>)
  Clear(bufnr)
  Forget(bufnr)
  if hints->empty()
    return
  endif
  Define()
  var here: list<dict<any>> = []
  for hint in hints
    if type(hint) != v:t_dict
      continue
    endif
    var text = LabelText(hint)
    if text->empty()
      continue
    endif
    if hint->get('paddingLeft', false)
      text = ' ' .. text
    endif
    if hint->get('paddingRight', false)
      text ..= ' '
    endif
    var [lnum, col] = util.PosFromLsp(bufnr, hint->get('position', {}))
    try
      prop_add(lnum, col, {
	bufnr: bufnr,
	type: TYPES->get(hint->get('kind', KIND_TYPE), TYPES[KIND_TYPE]),
	text: text,
      })
      here->add({lnum: lnum, col: col, hint: hint})
    catch /E96[4-6]/
      # The buffer moved on while the answer was on its way.
    endtry
  endfor
  shown[string(bufnr)] = here
enddef

# test/run sets this to have every :def compiled as the script is read.
if $LSP_COMPILE_CHECK != ''
  defcompile
endif

# vim: sw=2 sts=2 et
