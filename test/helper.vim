vim9script
# What the tests use to drive a server of their own.

const HERE = expand('<sfile>:p:h')
const SCENARIO = HERE .. '/Xscenario.json'
const TRACE = HERE .. '/Xtrace.jsonl'
# What runs fakeserver.py.  Windows installs "python", elsewhere it is
# "python3"; $PYTHON names another one.
const PYTHON = !empty($PYTHON) ? $PYTHON
  : !empty(exepath('python3')) ? 'python3' : 'python'
export const CMD = [PYTHON, HERE .. '/fakeserver.py']

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
# answers the way "scenario" holds.  The scenario takes "capabilities",
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
    cmd: CMD,
    rootPatterns: ['.git'],
  }, server)]

  writefile(lines, SRC)
  execute 'edit! ' .. fnameescape(SRC)
  setfiletype c

  # Starting Python for the first time is slow on a cold machine, so this
  # waits longer than anything else does.
  var ready = WaitFor(() => execute('LspStatus') =~ 'ready', 30000)
  if !ready
    # Report what the server did instead, there is no guessing from "false".
    add(v:errors, 'the server did not come up; status: '
      .. execute('LspStatus')->trim()
      .. '; stderr: ' .. string(execute('LspLog')->trim()))
  endif
  return ready
enddef

# The same for more than one server on the same buffer.  Each entry of "specs"
# takes the "scenario" that server answers from and what to add to its
# g:lsp_server_list entry under "server"; they are named in the order given,
# which is the order the client asks them in.  Each gets a scenario and a
# trace of its own, read back with TraceOf() and SentTo().
export def StartServers(specs: list<dict<any>>, lines: list<string>): bool
  var list: list<dict<any>> = []
  for i in range(len(specs))
    var scenario = ScenarioOf(i)
    var trace = TraceFile(i)
    writefile([json_encode(specs[i]->get('scenario', {}))], scenario)
    delete(trace)
    list->add(extend({
      name: printf('fake%d', i),
      filetypes: ['c'],
      cmd: CMD + [scenario, trace],
      rootPatterns: ['.git'],
    }, specs[i]->get('server', {})))
  endfor
  g:lsp_server_list = list

  writefile(lines, SRC)
  execute 'edit! ' .. fnameescape(SRC)
  setfiletype c

  var ready = WaitFor(() => execute('LspStatus')->split("\n")
    ->filter((_, line) => line =~ 'ready')->len() == len(specs), 30000)
  if !ready
    add(v:errors, 'the servers did not come up; status: '
      .. execute('LspStatus')->trim())
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
  for i in range(MOST_SERVERS)
    delete(ScenarioOf(i))
    delete(TraceFile(i))
  endfor
  delete(SRC)
enddef

# How many servers a test may start, which is what StopServer() clears up
# after.
const MOST_SERVERS = 4

def ScenarioOf(i: number): string
  return HERE .. printf('/Xscenario%d.json', i)
enddef

def TraceFile(i: number): string
  return HERE .. printf('/Xtrace%d.jsonl', i)
enddef

# What the client sent, in the order it arrived.
export def Trace(): list<dict<any>>
  return Messages(TRACE)
enddef

# The same for the server StartServers() named at "i".
export def TraceOf(i: number): list<dict<any>>
  return Messages(TraceFile(i))
enddef

export def SentTo(i: number, method: string): list<dict<any>>
  return TraceOf(i)->filter((_, m) => m->get('method', '') == method)
enddef

def Messages(path: string): list<dict<any>>
  if !filereadable(path)
    return []
  endif
  var messages: list<dict<any>> = []
  for line in readfile(path)
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
  return Trace()->filter((_, m) => m->get('method', '') == method)
enddef

# vim: ts=2 sw=0 et
