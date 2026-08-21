vim9script
# Runs every Test_ function in test/test_*.vim and reports what failed.
# Started by test/run, which is what to use.

const HERE = expand('<sfile>:p:h')

set nocompatible
set noswapfile
set nomore
set belloff=all
set cmdheight=10
const PLUGIN = fnamemodify(HERE, ':h')
execute 'set runtimepath^=' .. PLUGIN
filetype plugin indent on
# Started with -u NONE, so nothing under runtimepath has been loaded; the
# plugin has to be brought in by hand.
execute 'source ' .. fnameescape(PLUGIN .. '/plugin/lsp.vim')

import './helper.vim' as helper

var failed: list<string> = []
var ran = 0
var report: list<string> = []

def Say(line: string)
  add(report, line)
enddef

def RunOne(name: string)
  ran += 1
  v:errors = []
  try
    execute 'call g:' .. name .. '()'
  catch
    add(v:errors, v:throwpoint .. ': ' .. v:exception)
  endtry
  helper.StopServer()
  silent! :%bwipe!

  if v:errors->empty()
    Say('ok     ' .. name)
  else
    add(failed, name)
    Say('FAILED ' .. name)
    for err in v:errors
      Say('       ' .. err)
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

  Say(printf('%d run, %d failed', ran, len(failed)))
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
