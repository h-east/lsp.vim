vim9script

# LSP client for Vim - the places in a file that lead somewhere
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 27

import './util.vim'

const TYPE = 'LspDocumentLink'

# What is marked in which buffer, so the one under the cursor can be opened.
var links: dict<list<dict<any>>> = {}

var defined = false

def Define()
  if defined
    return
  endif
  highlight default link LspDocumentLink Underlined
  if prop_type_get(TYPE)->empty()
    prop_type_add(TYPE, {highlight: TYPE})
  endif
  defined = true
enddef

export def Clear(bufnr: number)
  if links->has_key(string(bufnr))
    remove(links, string(bufnr))
  endif
  if !defined || !bufexists(bufnr)
    return
  endif
  prop_remove({bufnr: bufnr, type: TYPE, all: true})
enddef

export def Update(bufnr: number, items: list<any>)
  Clear(bufnr)
  if items->empty()
    return
  endif
  Define()
  var kept: list<dict<any>> = []
  for item in items
    if type(item) != v:t_dict || type(item->get('range', 0)) != v:t_dict
      continue
    endif
    var [lnum, col] = util.PosFromLsp(bufnr, item.range->get('start', {}))
    var [end_lnum, end_col] = util.PosFromLsp(bufnr,
					      item.range->get('end', {}))
    if end_lnum == lnum && end_col <= col
      continue		# nothing to point at
    endif
    try
      prop_add(lnum, col, {end_lnum: end_lnum, end_col: end_col,
			   bufnr: bufnr, type: TYPE})
    catch /^Vim\%((\a\+)\)\=:E96[456]:/
      # The buffer moved on since the server looked at it; the next round
      # will line up again.
      continue
    endtry
    kept->add({lnum: lnum, col: col, end_lnum: end_lnum, end_col: end_col,
	       link: item})
  endfor
  links[string(bufnr)] = kept
enddef

# The link the position falls in, empty when there is none.
export def At(bufnr: number, lnum: number, col: number): dict<any>
  for item in links->get(string(bufnr), [])
    if (lnum > item.lnum || (lnum == item.lnum && col >= item.col))
	  && (lnum < item.end_lnum
	      || (lnum == item.end_lnum && col < item.end_col))
      return item.link
    endif
  endfor
  return {}
enddef

# What the server returned for this one, kept so it is asked for once.
export def Resolved(bufnr: number, link: dict<any>, full: dict<any>)
  for item in links->get(string(bufnr), [])
    if item.link is link
      item.link = full
      return
    endif
  endfor
enddef
