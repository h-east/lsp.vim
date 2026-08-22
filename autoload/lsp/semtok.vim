vim9script

# LSP client for Vim - the highlighting a server works out from what it parsed
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 23

import './util.vim'

# The token types the protocol names itself, each linked to the group Vim
# already uses for that kind of thing.  A server is free to put others in its
# legend; a token of a type that is not here is left to the syntax
# highlighting.
const LINKS = {
  namespace: 'Identifier',
  type: 'Type',
  class: 'Type',
  enum: 'Type',
  interface: 'Type',
  struct: 'Type',
  typeParameter: 'Type',
  parameter: 'Identifier',
  variable: 'Identifier',
  property: 'Identifier',
  enumMember: 'Constant',
  event: 'Identifier',
  function: 'Function',
  method: 'Function',
  macro: 'Macro',
  keyword: 'Keyword',
  modifier: 'StorageClass',
  comment: 'Comment',
  string: 'String',
  number: 'Number',
  regexp: 'SpecialChar',
  operator: 'Operator',
  decorator: 'PreProc',
}

# The property type made for a token type, an empty string for one this client
# has no group for.  Made on the way past rather than up front: a legend names
# every type the server knows, most of which never turn up.
var types: dict<string> = {}

def PropType(name: string): string
  if types->has_key(name)
    return types[name]
  endif
  if !LINKS->has_key(name)
    types[name] = ''
    return ''
  endif
  var group = 'LspSem' .. toupper(name[0]) .. name[1 : ]
  execute 'highlight default link' group LINKS[name]
  if prop_type_get(group)->empty()
    prop_type_add(group, {highlight: group})
  endif
  types[name] = group
  return group
enddef

# What the server last answered with, by buffer: "id" is what a delta is asked
# against, "data" what it is applied to.
var state: dict<dict<any>> = {}

export def ResultId(bufnr: number): string
  return state->get(string(bufnr), {})->get('id', '')
enddef

export def Forget(bufnr: number)
  var key = string(bufnr)
  if state->has_key(key)
    remove(state, key)
  endif
enddef

export def Clear(bufnr: number)
  if !bufexists(bufnr)
    return
  endif
  var names = types->values()->filter((_, group) => !group->empty())
  if !names->empty()
    prop_remove({bufnr: bufnr, types: names, all: true})
  endif
enddef

# Five numbers stand for one token, each counted from the one before it: the
# line from the previous line, the start from the previous start when they
# share a line, then the length, the type and the modifiers.  Only the type is
# used here.
def Paint(bufnr: number, legend: dict<any>, data: list<number>)
  Clear(bufnr)
  var token_types = legend->get('tokenTypes', [])
  var by_type: dict<list<list<number>>> = {}
  var line = 0
  var char = 0
  var lnum = -1
  var text = ''
  var known = false
  var at = 0
  while at + 4 < len(data)
    line += data[at]
    char = data[at] == 0 ? char + data[at + 1] : data[at + 1]
    var length = data[at + 2]
    var group = PropType(token_types->get(data[at + 3], ''))
    at += 5
    if group->empty() || length <= 0
      continue
    endif
    if line + 1 != lnum
      lnum = line + 1
      var got = getbufline(bufnr, lnum)
      known = !got->empty()
      text = got->get(0, '')
    endif
    if !known
      continue
    endif
    var col = util.ColFromLsp(text, char)
    var end_col = util.ColFromLsp(text, char + length)
    if end_col <= col
      continue
    endif
    if by_type->has_key(group)
      by_type[group]->add([lnum, col, lnum, end_col])
    else
      by_type[group] = [[lnum, col, lnum, end_col]]
    endif
  endwhile
  for [group, items] in by_type->items()
    try
      prop_add_list({bufnr: bufnr, type: group}, items)
    catch /E96[4-6]/
      # The buffer moved on while the answer was on its way; the next one will
      # be about the buffer as it is now.
    endtry
  endfor
enddef

# A full answer carries "data", a delta answer the "edits" that turn what was
# there into it.  Returns whether the buffer was painted; what is left of an
# answer that could not be used is nothing to ask a delta against.
export def Update(bufnr: number, legend: dict<any>, result: any): bool
  if type(result) != v:t_dict
    Clear(bufnr)
    Forget(bufnr)
    return false
  endif
  var key = string(bufnr)
  var data: list<number>
  if result->has_key('edits')
    data = state->get(key, {})->get('data', [])->copy()
    # An edit names a place in the data as it was, so a later one is applied
    # before an earlier one moves it.
    for edit in result.edits->copy()->sort((a, b) =>
					  b->get('start', 0) - a->get('start', 0))
      var start = edit->get('start', 0)
      var deleted = edit->get('deleteCount', 0)
      if start < 0 || start > len(data) || start + deleted > len(data)
	# There is nothing to apply the delta to, so it is dropped and the
	# next answer is asked for in full.
	Forget(bufnr)
	return false
      endif
      if deleted > 0
	remove(data, start, start + deleted - 1)
      endif
      var added = edit->get('data', [])
      if !added->empty()
	extend(data, added, start)
      endif
    endfor
  else
    data = result->get('data', [])
  endif
  state[key] = {id: result->get('resultId', ''), data: data}
  Paint(bufnr, legend, data)
  return true
enddef

# vim: sw=2 sts=2 et
