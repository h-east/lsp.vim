vim9script
# Runs every Test_ function in test/test_*.vim and reports what failed.
# Started by test/run, which is what to use.

const HERE = expand('<sfile>:p:h')

set nocompatible
set noswapfile
set nomore
set belloff=all
set cmdheight=10
if exists('+shellslash')
  set shellslash
endif
const PLUGIN = fnamemodify(HERE, ':h')
execute 'set runtimepath^=' .. PLUGIN
filetype plugin indent on
# Started with -u NONE, so nothing under runtimepath has been loaded; the
# plugin has to be brought in by hand.
execute 'source ' .. fnameescape(PLUGIN .. '/plugin/lsp.vim')

# The plugin gives up quietly on a Vim that is too old, which would leave
# every test failing on a missing command.  Report what is wrong instead.
if !exists(':LspStart')
  writefile(['This Vim cannot run the plugin, so nothing was tested.',
    'It needs 9.2.1004 or later with +job and +channel; this one is '
    .. v:versionlong .. (has('job') ? '' : ' without +job')
    .. (has('channel') ? '' : ' without +channel') .. '.',
    'Name another with $VIMPROG:',
    '    VIMPROG=/path/to/vim ./run'], HERE .. '/messages')
  cquit 1
endif

import './helper.vim' as helper

var failed: list<string> = []
var ran = 0
var report: list<string> = []

def Report(line: string)
  add(report, line)
enddef

def RunOne(name: string)
  ran += 1
  v:errors = []
  v:errmsg = ''
  try
    execute 'call g:' .. name .. '()'
  catch
    add(v:errors, v:throwpoint .. ': ' .. v:exception)
  endtry
  # An error Vim reported without stopping the test, a compile check among
  # them, would otherwise be lost.
  if v:errmsg != ''
    add(v:errors, 'an error went unreported: ' .. v:errmsg)
  endif
  helper.StopServer()
  # The quickfix stack outlives a buffer, so the next test would find what
  # this one left there and take it for its own.
  setqflist([], 'f')
  silent! :%bwipe!

  if v:errors->empty()
    Report('ok     ' .. name)
  else
    add(failed, name)
    Report('FAILED ' .. name)
    for err in v:errors
      Report('       ' .. err)
    endfor
  endif
enddef

def Main()
  for file in glob(HERE .. '/test_*.vim', false, true)->sort()
    execute 'source ' .. fnameescape(file)
    var names = getcompletion('Test_', 'function')
      ->mapnew((_, n) => n->substitute('()\=$', '', ''))
      ->sort()
    # $TEST_FILTER narrows a run down to what is being looked at.
    for name in names
      if $TEST_FILTER ==# '' || name =~ $TEST_FILTER
        RunOne(name)
      endif
    endfor
    # The next file brings its own; these would otherwise run again.
    for name in names
      execute 'delfunction g:' .. name
    endfor
  endfor

  Report(printf('%d run, %d failed', ran, len(failed)))
  writefile(report, HERE .. '/messages')
  for line in report
    echomsg line
  endfor
  execute 'cquit' .. (failed->empty() ? ' 0' : ' 1')
enddef

try
  Main()
catch
  writefile(['the runner itself failed:', v:throwpoint, v:exception],
    HERE .. '/messages')
  cquit 1
endtry

# vim: ts=2 sw=0 et
