vim9script

# LSP client for Vim - what the server has to say about a line, above it
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 22

import './util.vim'

const TYPE = 'LspCodeLens'

# What is shown above which line, so the one under the cursor can be run.
var lenses: dict<dict<list<dict<any>>>> = {}

var defined = false

def Define()
  if defined
    return
  endif
  # This is text the file does not hold, so it is kept quiet.
  highlight default link LspCodeLens Comment
  if prop_type_get(TYPE)->empty()
    prop_type_add(TYPE, {highlight: TYPE})
  endif
  defined = true
enddef

export def Clear(bufnr: number)
  if lenses->has_key(string(bufnr))
    remove(lenses, string(bufnr))
  endif
  if !defined || !bufexists(bufnr)
    return
  endif
  prop_remove({bufnr: bufnr, type: TYPE, all: true})
enddef

# A lens with no command is one the server has not worked out yet; it says so
# by offering to resolve it, which is asked for before this is called.
def Title(lens: dict<any>): string
  var cmd = lens->get('command', {})
  return type(cmd) == v:t_dict ? cmd->get('title', '') : ''
enddef

# What the lens is about starts where its range does, so the text above lines
# up with it rather than with the margin.
def Indent(bufnr: number, lnum: number): string
  var line = getbufline(bufnr, lnum)->get(0, '')
  return line->matchstr('^\s*')
enddef

export def Update(bufnr: number, items: list<any>)
  Clear(bufnr)
  if items->empty()
    return
  endif
  Define()
  # More than one lens on a line is shown as one row, in the order they
  # arrived, which is the order a server means them to be read in.
  var here: dict<list<dict<any>>> = {}
  var order: list<number> = []
  for lens in items
    if type(lens) != v:t_dict || Title(lens)->empty()
      continue
    endif
    var lnum = util.PosFromLsp(bufnr,
			  lens->get('range', {})->get('start', {}))[0]
    if !here->has_key(string(lnum))
      here[string(lnum)] = []
      order->add(lnum)
    endif
    here[string(lnum)]->add(lens)
  endfor
  for lnum in order
    try
      prop_add(lnum, 0, {
	bufnr: bufnr,
	type: TYPE,
	text: Indent(bufnr, lnum) .. here[string(lnum)]
		->mapnew((_, l) => Title(l))->join(' | '),
	text_align: 'above',
      })
    catch /E96[4-6]/
      # The buffer moved on while the answer was on its way.
    endtry
  endfor
  lenses[string(bufnr)] = here
enddef

export def ForLine(bufnr: number, lnum: number): list<dict<any>>
  return lenses->get(string(bufnr), {})->get(string(lnum), [])
enddef

export def Count(bufnr: number): number
  var found = 0
  for list in lenses->get(string(bufnr), {})->values()
    found += len(list)
  endfor
  return found
enddef

# vim: sw=2 sts=2 et
