vim9script

# LSP client for Vim - growing the selection the way the file is built
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 27

import './util.vim'

# The ranges the server gave, innermost first, and where in them the
# selection stands.  Kept so that growing again costs no request.
var steps: list<list<number>> = []
var at = -1
var for_buf = 0
var for_tick = 0
# Where the run began, to go back to once it is stepped all the way in.
var began: list<number> = []
var began_visual = false

export def Forget()
  steps = []
  at = -1
  for_buf = 0
  began = []
enddef

# The selection as it is now, ends the way a range has them.
def Now(): list<number>
  var from = getpos('v')
  var to = getpos('.')
  if from[1] > to[1] || (from[1] == to[1] && from[2] > to[2])
    [from, to] = [to, from]
  endif
  return [from[1], from[2], to[1], to[2]]
enddef

# What the remembered step put on screen is what has to be there still.
def Fresh(): bool
  return !steps->empty() && at >= 0
      && for_buf == bufnr('%') && for_tick == b:changedtick
      && mode() =~# "^[vV\<C-v>]" && Now() == steps[at]
enddef

# The character before a position, which is where a range ends for Vim: the
# protocol has the end just past the last character.
def Before(lnum: number, col: number): list<number>
  var l = lnum
  var c = col
  if c <= 1
    if l <= 1
      return [lnum, 1]
    endif
    l -= 1
    c = getline(l)->strlen() + 1
  endif
  var last = strpart(getline(l), 0, c - 1)->matchstr('.$')
  return [l, max([1, c - last->strlen()])]
enddef

# The chain as it arrived, kept as the positions Vim selects between.
export def Remember(bufnr: number, chain: any)
  var was_visual = mode() =~# "^[vV\<C-v>]"
  var was = was_visual ? Now() : [line('.'), col('.'), line('.'), col('.')]
  Forget()
  began = was
  began_visual = was_visual
  var node = chain
  while type(node) == v:t_dict && type(node->get('range', 0)) == v:t_dict
    var [lnum, col] = util.PosFromLsp(bufnr, node.range->get('start', {}))
    var [end_lnum, end_col] = util.PosFromLsp(bufnr,
					      node.range->get('end', {}))
    # A range with nothing in it holds nothing to select.
    if end_lnum > lnum || end_col > col
      var step = [lnum, col] + Before(end_lnum, end_col)
      if steps->empty() || step != steps[-1]
	steps->add(step)
      endif
    endif
    node = node->get('parent', 0)
  endwhile
  for_buf = bufnr
  for_tick = b:changedtick
enddef

# Put the step on screen, always character wise however the last selection
# was made.
def Show(step: list<number>)
  if mode() =~# "^[vV\<C-v>]"
    execute "normal! \<Esc>"
  endif
  cursor(step[0], step[1])
  normal! v
  cursor(step[2], step[3])
enddef

# One step out, or in with -1.  False when there is nothing remembered to
# step through, so the caller knows to ask.
export def Step(by: number): bool
  if !Fresh()
    return false
  endif
  var to = at + by
  if to >= len(steps)
    util.WarningMsg('there is nothing wider')
    return true
  endif
  if to < 0
    # All the way in is where it began, selection and all.
    at = -1
    if began_visual
      Show(began)
    else
      execute "normal! \<Esc>"
      cursor(began[0], began[1])
    endif
    return true
  endif
  at = to
  Show(steps[at])
  return true
enddef

# The innermost of what just arrived, or the one after it where the selection
# is already what the innermost holds.
export def Start(): bool
  if steps->empty()
    return false
  endif
  at = 0
  if mode() =~# "^[vV\<C-v>]" && Now() == steps[0] && len(steps) > 1
    at = 1
  endif
  Show(steps[at])
  redraw
  return true
enddef
