vim9script
# What the tests use to drive a server of their own.

const HERE = expand('<sfile>:p:h')
const SCENARIO = HERE .. '/Xscenario.json'
const TRACE = HERE .. '/Xtrace.jsonl'
# What runs fakeserver.py.  Windows installs "python", elsewhere it is
# "python3"; $PYTHON names another one.
const PYTHON = !empty($PYTHON) ? $PYTHON
	    : !empty(exepath('python3')) ? 'python3' : 'python'

# Waits for something to become true, checking often enough that a test does
# not spend its time asleep.
export def WaitFor(Cond: func(): bool, msecs = 2000): bool
  for _ in range(msecs / 10)
    if Cond()
      return true
    endif
    sleep 10m
  endfor
  return Cond()
enddef

# The file the tests work on.  It sits next to them, so the root marker the
# server is told about is the one above.
export const SRC = HERE .. '/Xsrc.c'

# Writes "lines" to the source file, opens it, and hands it to a server that
# answers the way "scenario" says.  The scenario takes "capabilities",
# "notify" and "replies"; see fakeserver.py.  What "server" holds is added to
# the entry in g:lsp_server_list.
#
# The scenario has to be in place before the buffer is opened: setting the
# filetype is what attaches it, and a server started without a scenario to
# read gives up at once.  Returns false when the server never came up.
export def StartServer(scenario: dict<any>, lines: list<string>,
						  server: dict<any> = {}): bool
  writefile([json_encode(scenario)], SCENARIO)
  delete(TRACE)
  $LSP_SCENARIO = SCENARIO
  $LSP_TRACE = TRACE
  g:lsp_server_list = [extend({
    name: 'fake',
    filetypes: ['c'],
    cmd: [PYTHON, HERE .. '/fakeserver.py'],
    rootPatterns: ['.git'],
  }, server)]

  writefile(lines, SRC)
  execute 'edit! ' .. fnameescape(SRC)
  setfiletype c

  var ready = WaitFor(() => execute('LspStatus') =~# 'ready')
  if !ready
    # Say what the server did instead, there is no guessing from "false".
    add(v:errors, 'the server did not come up; status: '
		  .. execute('LspStatus')->trim()
		  .. '; stderr: ' .. string(execute('LspLog')->trim()))
  endif
  return ready
enddef

export def StopServer()
  try
    LspStop
  catch
  endtry
  delete(SCENARIO)
  delete(TRACE)
  delete(SRC)
enddef

# What the client sent, in the order it arrived.
export def Trace(): list<dict<any>>
  if !filereadable(TRACE)
    return []
  endif
  var messages: list<dict<any>> = []
  for line in readfile(TRACE)
    # The server may be part way through writing the last line.  It is whole
    # by the next read, which is what the caller is waiting for anyway.
    try
      messages->add(json_decode(line))
    catch
      break
    endtry
  endfor
  return messages
enddef

export def Sent(method: string): list<dict<any>>
  return Trace()->filter((_, m) => m->get('method', '') ==# method)
enddef
