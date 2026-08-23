vim9script

# LSP client for Vim - the folds a server works out from the syntax
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 22

# 'foldexpr' is asked about one line at a time and often, so the level of
# every line is worked out once and looked up after that.
var levels: dict<list<number>> = {}

export def Clear(bufnr: number)
  var key = string(bufnr)
  if levels->has_key(key)
    remove(levels, key)
  endif
enddef

# A line's level is how many ranges are wrapped around it.
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

# 'foldexpr' for a buffer whose folds the server works out.
export def Expr(lnum: number): string
  var level = levels->get(string(bufnr('%')), [])
  if lnum < 1 || lnum > len(level)
    return '0'
  endif
  return string(level[lnum - 1])
enddef

# A :def function is compiled when it is first called, so what is wrong with
# one that is never reached only shows up as E1091 later on.  test/run sets
# this to have every function compiled here and now.
if $LSP_COMPILE_CHECK != ''
  defcompile
endif

# vim: sw=2 sts=2 et
