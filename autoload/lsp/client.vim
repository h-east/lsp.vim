vim9script

# LSP client for Vim - one server process and the JSON-RPC traffic to it
# Maintainer: Hirohito Higashi <h.east.727@gmail.com>
# Latest Change: 2026 Aug 21
#
# Vim itself frames the messages and matches responses to requests when the
# channel is opened in "lsp" mode, see |language-server-protocol|.  What is
# left for this file is the handshake, the request bookkeeping and turning
# server messages into calls into the rest of the plugin.

import autoload './util.vim'

# Server requests this plugin answers.  Anything else gets a "method not
# found" error, which servers are required to cope with.
const METHOD_NOT_FOUND = -32601

# Called with (client, method, params) for every notification from a server.
# Set by lsp.vim, which owns what happens with them.
var NotifyHandler: func(dict<any>, string, any)

export def SetNotifyHandler(Handler: func(dict<any>, string, any))
  NotifyHandler = Handler
enddef

# Answers a request the server made.  Returns whether it dealt with it; what
# it did not deal with is turned down here.
var RequestHandler: func(dict<any>, string, any, func(any)): bool

export def SetRequestHandler(
	Handler: func(dict<any>, string, any, func(any)): bool)
  RequestHandler = Handler
enddef

def ClientCapabilities(): dict<any>
  return {
    general: {
      positionEncodings: ['utf-16'],
    },
    textDocument: {
      synchronization: {
	didSave: true,
	willSave: false,
	dynamicRegistration: false,
      },
      completion: {
	dynamicRegistration: false,
	contextSupport: false,
	completionItem: {
	  # Placeholders cannot be expanded, so ask for plain text.  Without
	  # saying so a server is free to send snippets.
	  snippetSupport: false,
	  documentationFormat: ['plaintext', 'markdown'],
	  # Not asking for labelDetailsSupport on purpose: a server that has
	  # it puts the signature in "labelDetails" and leaves a bare name in
	  # "label", while the popup menu is better off with the whole thing
	  # in one string.
	},
      },
      hover: {
	contentFormat: ['plaintext', 'markdown'],
	dynamicRegistration: false,
      },
      signatureHelp: {
	dynamicRegistration: false,
	signatureInformation: {
	  documentationFormat: ['plaintext', 'markdown'],
	  activeParameterSupport: true,
	  # Ask for the parameter positions as offsets into the signature
	  # rather than as text to search for, so the active one can be
	  # highlighted without guessing which occurrence is meant.
	  parameterInformation: {labelOffsetSupport: true},
	},
      },
      definition: {
	linkSupport: false,
	dynamicRegistration: false,
      },
      declaration: {
	linkSupport: false,
	dynamicRegistration: false,
      },
      typeDefinition: {
	linkSupport: false,
	dynamicRegistration: false,
      },
      implementation: {
	linkSupport: false,
	dynamicRegistration: false,
      },
      documentSymbol: {
	dynamicRegistration: false,
	# Asking for the tree, since where a symbol sits in it is worth
	# showing; the flat list a server may send instead is read as well.
	hierarchicalDocumentSymbolSupport: true,
      },
      codeAction: {
	dynamicRegistration: false,
	# Without this a server answers with Commands, which it has to be
	# asked to run; a CodeAction carries the edit itself.  The empty
	# string in the set is what the protocol asks for so that a kind
	# this client has never heard of still comes through.
	codeActionLiteralSupport: {
	  codeActionKind: {
	    valueSet: ['', 'quickfix', 'refactor', 'refactor.extract',
		       'refactor.inline', 'refactor.rewrite', 'source',
		       'source.organizeImports'],
	  },
	},
      },
      publishDiagnostics: {
	relatedInformation: true,
      },
    },
    workspace: {
      workspaceFolders: false,
      # A server that works a change out on its side hands it over this way,
      # which is how an action it runs itself comes back.
      applyEdit: true,
    },
    window: {
      # A server only reports what it is busy with when it is told someone is
      # listening.  Indexing a large project takes long enough to be worth
      # saying so.
      workDoneProgress: true,
    },
  }
enddef

def OnExit(client: dict<any>, job: job, status: number)
  client.running = false
  client.initialized = false
  if status != 0 && !client.stopping
    util.ErrorMsg(printf('server "%s" exited with status %d',
						      client.name, status))
  endif
enddef

def OnStderr(client: dict<any>, ch: channel, msg: string)
  # Servers use stderr for their own logging.  Keep it out of the way, it is
  # available with :LspLog when the user asks for it.
  add(client.stderr, msg)
  if len(client.stderr) > 200
    remove(client.stderr, 0, len(client.stderr) - 201)
  endif
enddef

def Respond(client: dict<any>, id: any, result: any)
  ch_sendexpr(client.channel, {id: id, result: result})
enddef

def RespondError(client: dict<any>, id: any, code: number, message: string)
  ch_sendexpr(client.channel, {id: id, error: {code: code, message: message}})
enddef

# A message from the server that is not a reply to one of our requests: either
# a notification or a request that wants an answer.
def OnMessage(client: dict<any>, ch: channel, msg: dict<any>)
  var method = msg->get('method', '')
  if method->empty()
    return
  endif
  if msg->has_key('id')
    # A request.  Only the ones a client must answer are handled.
    if method ==# 'client/registerCapability'
	  || method ==# 'client/unregisterCapability'
      Respond(client, msg.id, v:null)
    elseif method ==# 'workspace/configuration'
      # No per-server configuration is kept, answer with a null for each item.
      var items = msg->get('params', {})->get('items', [])
      Respond(client, msg.id, items->mapnew((_, _) => v:null))
    elseif RequestHandler == null_function
	  || !RequestHandler(client, method, msg->get('params', {}),
			     (result) => Respond(client, msg.id, result))
      RespondError(client, msg.id, METHOD_NOT_FOUND,
					  'method not supported: ' .. method)
    endif
  elseif NotifyHandler != null_function
    NotifyHandler(client, method, msg->get('params', {}))
  endif
enddef

# Send a notification.  Nothing comes back, so nothing is waited for.
export def Notify(client: dict<any>, method: string, params: any = {})
  if !client.running
    return
  endif
  ch_sendexpr(client.channel, {method: method, params: params})
enddef

# Send a request.  "Cb" is called with the "result" of the reply; an error
# reply is reported and Cb is not called.  Returns the request id, which can
# be passed to Cancel().
export def Request(client: dict<any>, method: string, params: any,
						  Cb: func(any)): number
  if !client.running
    return -1
  endif
  var status = ch_sendexpr(client.channel, {method: method, params: params},
      {callback: (ch: channel, reply: dict<any>) => {
	if reply->has_key('error')
	  var err = reply.error
	  util.ErrorMsg(printf('%s: %s', method, err->get('message', '')))
	  return
	endif
	Cb(reply->get('result', v:null))
      }})
  return status->get('id', -1)
enddef

# Send a request and wait for the reply.  Vim's completion functions have to
# answer on the spot, which is what this is for; everything else should use
# Request().  Returns v:null on an error or when "timeout" milliseconds pass.
export def RequestSync(client: dict<any>, method: string, params: any,
						   timeout: number): any
  if !client.running
    return v:null
  endif
  var reply = ch_evalexpr(client.channel, {method: method, params: params},
							{timeout: timeout})
  if type(reply) != v:t_dict || reply->empty()
    # An empty reply is what running out of time looks like.  Say so: without
    # it the caller returns nothing and the user is left guessing.
    util.WarningMsg(printf('%s: no answer within %dms', method, timeout))
    return v:null
  endif
  if reply->has_key('error')
    util.ErrorMsg(printf('%s: %s', method,
				 reply.error->get('message', '')))
    return v:null
  endif
  return reply->get('result', v:null)
enddef

export def Cancel(client: dict<any>, id: number)
  if id > 0
    Notify(client, '$/cancelRequest', {id: id})
  endif
enddef

# Tell the server who we are and what we support.  The document
# synchronisation only starts once the reply is in, so "OnReady" is called
# from there.
def Initialize(client: dict<any>, OnReady: func(dict<any>))
  var params = {
    processId: getpid(),
    clientInfo: {name: 'Vim', version: v:versionlong->string()},
    rootUri: util.PathToUri(client.root),
    workspaceFolders: v:null,
    capabilities: ClientCapabilities(),
    trace: 'off',
  }
  Request(client, 'initialize', params, (result: any) => {
    if type(result) != v:t_dict
      util.ErrorMsg('server "' .. client.name .. '" sent no capabilities')
      return
    endif
    client.capabilities = result->get('capabilities', {})
    Notify(client, 'initialized', {})
    client.initialized = true
    OnReady(client)
  })
enddef

# Start a server described by "config" with "root" as its workspace root.
# Returns an empty Dict when the server could not be started.
export def Start(config: dict<any>, root: string,
			      OnReady: func(dict<any>)): dict<any>
  if !executable(config.cmd[0])
    util.ErrorMsg('cannot execute "' .. config.cmd[0] .. '"')
    return {}
  endif

  var client: dict<any> = {
    name: config.name,
    config: config,
    root: root,
    running: false,
    stopping: false,
    initialized: false,
    capabilities: {},
    stderr: [],
    log: [],
    documents: {},
    diagnostics: {},
  }

  var job = job_start(config.cmd, {
    in_mode: 'lsp',
    out_mode: 'lsp',
    err_mode: 'nl',
    cwd: root,
    noblock: true,
    out_cb: (ch, msg) => OnMessage(client, ch, msg),
    err_cb: (ch, msg) => OnStderr(client, ch, msg),
    exit_cb: (j, status) => OnExit(client, j, status),
  })
  if job_status(job) !=# 'run'
    util.ErrorMsg('failed to start "' .. config.name .. '"')
    return {}
  endif

  client.job = job
  client.channel = job_getchannel(job)
  client.running = true
  Initialize(client, OnReady)
  return client
enddef

# Shut the server down the way the protocol asks for: a "shutdown" request,
# then an "exit" notification.  The job is stopped as a fallback for a server
# that does not leave on its own.
export def Stop(client: dict<any>)
  if !client->get('running', false)
    return
  endif
  client.stopping = true
  Request(client, 'shutdown', v:null, (_) => {
    Notify(client, 'exit')
  })
enddef

# vim: sw=2 sts=2 et
