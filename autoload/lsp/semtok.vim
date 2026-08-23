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

# The modifiers this client paints itself, in the order one takes over from
# another when a token carries more than one.  A modifier that is not here is
# still usable: make a group for it and it is picked up.
const MOD_ORDER = ['deprecated', 'readonly']

var defined = false

def Define()
  if defined
    return
  endif
  for [name, group] in LINKS->items()
    execute 'highlight default link' Group(name) group
  endfor
  # No link for this one: a line through the text says "do not use it"
  # whatever the colors around it are.
  highlight default LspSemDeprecated term=strikethrough cterm=strikethrough
	\ gui=strikethrough
  highlight default link LspSemReadonly Constant
  defined = true
enddef

def Group(name: string): string
  return name->empty() ? '' : 'LspSem' .. toupper(name[0]) .. name[1 : ]
enddef

# One property type per group, made the first time a token needs it.
var props: dict<bool> = {}

def PropFor(group: string)
  if !props->has_key(group)
    if prop_type_get(group)->empty()
      prop_type_add(group, {highlight: group})
    endif
    props[group] = true
  endif
enddef

# The names of the modifiers a token carries, one bit each in the order the
# legend lists them.
def ModNames(names: list<string>, bits: number): list<string>
  var out: list<string> = []
  var rest = bits
  for name in names
    if rest == 0
      break
    endif
    if and(rest, 1) != 0
      out->add(name)
    endif
    rest = rest / 2
  endfor
  return out
enddef

# What a token is painted with: the first of LspSem<Type><Modifier>,
# LspSem<Modifier> and LspSem<Type> that exists.  An empty string leaves the
# token to the syntax highlighting, which is what a type this client has no
# group for gets.
def GroupFor(type_name: string, mods: list<string>): string
  var base = LINKS->has_key(type_name) ? Group(type_name) : ''
  if mods->empty()
    return base
  endif
  if !base->empty()
    for name in mods
      var group = base .. toupper(name[0]) .. name[1 : ]
      if hlexists(group)
	return group
      endif
    endfor
  endif
  for name in MOD_ORDER
    if index(mods, name) >= 0
      return Group(name)
    endif
  endfor
  for name in mods
    if hlexists(Group(name))
      return Group(name)
    endif
  endfor
  return base
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
  if !props->empty()
    prop_remove({bufnr: bufnr, types: props->keys(), all: true})
  endif
enddef

# Five numbers stand for one token, each counted from the one before it: the
# line from the previous line, the start from the previous start when they
# share a line, then the length, the type and the modifiers.
def Paint(bufnr: number, legend: dict<any>, data: list<number>)
  Clear(bufnr)
  Define()
  var token_types = legend->get('tokenTypes', [])
  var mod_names = legend->get('tokenModifiers', [])
  # The type and the modifiers together decide the group, and a file holds
  # only a handful of the combinations a legend allows.
  var by_token: dict<string> = {}
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
    var key = data[at + 3] .. ':' .. data[at + 4]
    if !by_token->has_key(key)
      by_token[key] = GroupFor(token_types->get(data[at + 3], ''),
			       ModNames(mod_names, data[at + 4]))
    endif
    var group = by_token[key]
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
    PropFor(group)
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

# A :def function is compiled when it is first called, so what is wrong with
# one that is never reached only shows up as E1091 later on.  test/run sets
# this to have every function compiled here and now.
if $LSP_COMPILE_CHECK != ''
  defcompile
endif

# vim: sw=2 sts=2 et
