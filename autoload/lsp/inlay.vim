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

# A label is a string, or the pieces of one that a server can say more about.
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

export def Update(bufnr: number, hints: list<any>)
  Clear(bufnr)
  if hints->empty()
    return
  endif
  Define()
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
    catch /E96[4-6]/
      # The buffer moved on while the answer was on its way.
    endtry
  endfor
enddef

# vim: sw=2 sts=2 et
