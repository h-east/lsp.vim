vim9script

# LSP client for Vim - the folds a server works out from the syntax
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 22

# 'foldexpr' is asked about one line at a time and often, so what every line
# answers is worked out once and looked up after that.
var levels: dict<list<string>> = {}

export def Clear(bufnr: number)
  var key = string(bufnr)
  if levels->has_key(key)
    remove(levels, key)
  endif
enddef

# A line's level is how many ranges are wrapped around it.  A line a range
# starts on is marked with ">": a level that does not change is one fold to
# Vim, so two ranges that meet would come out as one.
export def Update(bufnr: number, ranges: list<any>)
  var count = getbufinfo(bufnr)->get(0, {})->get('linecount', 0)
  if count <= 0
    Clear(bufnr)
    return
  endif
  var level = repeat([0], count)
  var starts = repeat([false], count)
  for range in ranges
    if type(range) != v:t_dict
      continue
    endif
    var first = range->get('startLine', -1)
    if first < 0 || first >= count
      continue
    endif
    var last = min([range->get('endLine', first), count - 1])
    for i in range(first, last)
      level[i] += 1
    endfor
    starts[first] = true
  endfor
  levels[string(bufnr)] = range(count)->mapnew((i, _) =>
    (starts[i] ? '>' : '') .. level[i])
enddef

# 'foldexpr' for a buffer whose folds the server works out.
export def Expr(lnum: number): string
  var lines = levels->get(string(bufnr('%')), [])
  if lnum < 1 || lnum > len(lines)
    return '0'
  endif
  return lines[lnum - 1]
enddef

# test/run sets this to have every :def compiled as the script is read.
if $LSP_COMPILE_CHECK != ''
  defcompile
endif

# vim: ts=2 sw=0 et
