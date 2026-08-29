vim9script

# LSP client for Vim - conversions between Vim and LSP representations
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21

# Characters that may appear in a URI path without being escaped.
const UNRESERVED = '[A-Za-z0-9\-._~/]'

def PercentEncode(s: string): string
  var out = ''
  for byte in str2blob([s])->blob2list()
    out ..= printf('%%%02X', byte)
  endfor
  return out
enddef

# An escape stands for one byte, not one character, so the bytes are collected
# first and only then read back as text.
def PercentDecode(s: string): string
  var bytes: list<number> = []
  var i = 0
  var len = strlen(s)
  while i < len
    var c = strpart(s, i, 1)
    if c == '%' && i + 2 < len
      bytes->add(str2nr(strpart(s, i + 1, 2), 16))
      i += 3
    else
      bytes->add(char2nr(c))
      i += 1
    endif
  endwhile
  return list2blob(bytes)->blob2str()->get(0, '')
enddef

# A relative name is made absolute first, so the result does not depend on the
# current directory.
export def PathToUri(path: string): string
  var full = fnamemodify(path, ':p')
  if has('win32')
    full = substitute(full, '\\', '/', 'g')
    # A drive letter needs a leading slash: "C:/x" becomes "/C:/x".
    if full =~ '^\a:'
      full = '/' .. full
    endif
  endif
  return 'file://' .. substitute(full, UNRESERVED .. '\@!.',
					      (m) => PercentEncode(m[0]), 'g')
enddef

# A URI with any other scheme is returned unchanged: there is no file for it
# to name.
export def UriToPath(uri: string): string
  if uri !~? '^file://'
    return uri
  endif
  var path = PercentDecode(uri[7 : ])
  if has('win32') && path =~ '^/\a:'
    path = path[1 : ]
  endif
  return simplify(path)
enddef

# The name to open a file under.  A server names it in full; Vim shows one
# under the current directory by the short name.
export def OpenName(path: string): string
  return fnamemodify(path, ':.')
enddef

# LSP counts a position the way the server chose at startup, Vim
# counts bytes.  "utf-8" is the same thing and needs no conversion; the other
# two count a composing character on its own.  Every direction rounds down to
# the start of a character.
var encodings: dict<string> = {}

export def SetEncoding(bufnr: number, encoding: string)
  encodings[string(bufnr)] = encoding
enddef

export def ForgetEncoding(bufnr: number)
  var key = string(bufnr)
  if encodings->has_key(key)
    remove(encodings, key)
  endif
enddef

export def ClearEncodings()
  encodings = {}
enddef

# UTF-16 is what a server that names none means.
export def Encoding(bufnr: number): string
  return encodings->get(string(bufnr), 'utf-16')
enddef

export def PosToLsp(bufnr: number, lnum: number, col: number): dict<number>
  var encoding = Encoding(bufnr)
  if encoding ==# 'utf-8'
    return {line: lnum - 1, character: col - 1}
  endif
  var line = getbufline(bufnr, lnum)->get(0, '')
  var idx = encoding ==# 'utf-32' ? charidx(line, col - 1, true)
				  : utf16idx(line, col - 1, 1)
  return {line: lnum - 1, character: idx < 0 ? 0 : idx}
enddef

# Takes the line itself rather than a buffer, so it also works for a file that
# is not open; the encoding has to come along for the same reason.
export def ColFromLsp(line: string, character: number,
					  encoding: string = 'utf-16'): number
  if encoding ==# 'utf-8'
    var last = line->strlen()
    return (character > last ? last : character) + 1
  endif
  var idx = encoding ==# 'utf-32' ? byteidxcomp(line, character)
				  : byteidxcomp(line, character, true)
  return (idx < 0 ? line->strlen() : idx) + 1
enddef

export def PosFromLsp(bufnr: number, pos: dict<number>): list<number>
  var lnum = pos->get('line', 0) + 1
  var line = getbufline(bufnr, lnum)->get(0, '')
  return [lnum, ColFromLsp(line, pos->get('character', 0), Encoding(bufnr))]
enddef

export def CursorPosToLsp(): dict<number>
  return PosToLsp(bufnr('%'), line('.'), col('.'))
enddef

# A loaded buffer wins over what is on disk so that unsaved changes count;
# bufnr() would take the path as a pattern, hence the walk.
export def FileLines(path: string): list<string>
  for info in getbufinfo({bufloaded: 1})
    if info.name ==# path
      return getbufline(info.bufnr, 1, '$')
    endif
  endfor
  return filereadable(path) ? readfile(path) : []
enddef

# Falls back to the directory of "path", so a server always gets a root.
export def FindRoot(path: string, patterns: list<string>): string
  var dir = fnamemodify(path, ':p:h')
  for pattern in patterns
    # The root is the directory holding the marker, not the marker itself, so
    # a directory marker needs one more ":h" than a file marker.
    var found = finddir(pattern, dir .. ';')
    if !found->empty()
      return fnamemodify(found, ':p:h:h')
    endif
    found = findfile(pattern, dir .. ';')
    if !found->empty()
      return fnamemodify(found, ':p:h')
    endif
  endfor
  return dir
enddef

export def ErrorMsg(msg: string)
  echohl ErrorMsg
  echomsg 'lsp: ' .. msg
  echohl None
enddef

export def WarningMsg(msg: string)
  echohl WarningMsg
  echomsg 'lsp: ' .. msg
  echohl None
enddef

# test/run sets this to have every :def compiled as the script is read.
if $LSP_COMPILE_CHECK != ''
  defcompile
endif

# vim: sw=2 sts=2 et
