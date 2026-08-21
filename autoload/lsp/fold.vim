vim9script

# LSP client for Vim - the folds a server works out from the syntax
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 22

# The level of every line, by buffer.  'foldexpr' is asked about one line at a
# time and often, so the answer is worked out once and looked up after that.
var levels: dict<list<number>> = {}

export def Clear(bufnr: number)
  var key = string(bufnr)
  if levels->has_key(key)
    remove(levels, key)
  endif
enddef

# A range covers whole lines, "startLine" through "endLine".  A line's level
# is how many ranges are wrapped around it, which is what 'foldexpr' wants.
export def Update(bufnr: number, ranges: list<any>)
  var count = getbufinfo(bufnr)->get(0, {})->get('linecount', 0)
  if count <= 0
    Clear(bufnr)
    return
  endif
  var level = repeat([0], count)
  for range in ranges
    if type(range) != v:t_dict
      continue
    endif
    var first = range->get('startLine', -1)
    if first < 0
      continue
    endif
    var last = min([range->get('endLine', first), count - 1])
    for i in range(first, last)
      level[i] += 1
    endfor
  endfor
  levels[string(bufnr)] = level
enddef

# 'foldexpr' for a buffer whose folds the server works out.  A line nothing is
# known about folds with whatever is around it, which is what "=" says.
export def Expr(lnum: number): string
  var level = levels->get(string(bufnr('%')), [])
  if lnum < 1 || lnum > len(level)
    return '0'
  endif
  return string(level[lnum - 1])
enddef

# vim: sw=2 sts=2 et
