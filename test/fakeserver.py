#!/usr/bin/env python3
"""A language server that does as it is told.

What it does is read from the JSON file named by $LSP_SCENARIO:

    capabilities  what to answer "initialize" with
    notify        messages to send once "initialized" arrives, in order
    replies       result by method name, for requests that arrive later
    sequence      results by method name, one per request in the order they
                  are listed, the last of them answering the rest; this is
                  how a server changes its mind about what it said before
    errors        error by method name, for a request to be turned down
    ask           requests of the server's own, by the method that sets
                  them off, a notification included; this is how a server
                  hands over an edit.  An entry may name the "id" to ask
                  under, a string included

Every message that comes in is appended to $LSP_TRACE as one JSON object per
line, so a test can check what the client sent as well as what it did with
what came back.
"""
import json
import os
import sys

SCENARIO = json.load(open(os.environ['LSP_SCENARIO']))
TRACE = open(os.environ.get('LSP_TRACE', os.devnull), 'w')


_counter = [0]
_asked = {}


def next_id():
    _counter[0] += 1
    return _counter[0]


def result_for(method):
    answers = SCENARIO.get('sequence', {}).get(method)
    if not answers:
        return SCENARIO.get('replies', {}).get(method)
    at = _asked.get(method, 0)
    _asked[method] = min(at + 1, len(answers) - 1)
    return answers[at]


def read_msg():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        key, _, value = line.decode().partition(':')
        headers[key.strip().lower()] = value.strip()
    length = int(headers.get('content-length', 0))
    return json.loads(sys.stdin.buffer.read(length))


def send(msg):
    data = json.dumps(msg).encode()
    sys.stdout.buffer.write(b'Content-Length: %d\r\n\r\n' % len(data))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def trace(msg):
    TRACE.write(json.dumps(msg) + '\n')
    TRACE.flush()


def main():
    while True:
        msg = read_msg()
        if msg is None:
            return
        trace(msg)
        method = msg.get('method', '')

        if method == 'initialize':
            send({'jsonrpc': '2.0', 'id': msg['id'],
                  'result': {'capabilities': SCENARIO.get('capabilities', {})}})
        elif method == 'initialized':
            for item in SCENARIO.get('notify', []):
                send({'jsonrpc': '2.0', 'method': item['method'],
                      'params': item.get('params', {})})
        elif method == 'shutdown':
            send({'jsonrpc': '2.0', 'id': msg['id'], 'result': None})
        elif method == 'exit':
            return
        elif 'id' in msg and method:
            # Anything else that expects an answer gets what the scenario
            # holds for it, and null when it holds nothing.  A method named
            # under "errors" is turned down instead, the way a server does
            # with a part of what it offers that it has not implemented.
            error = SCENARIO.get('errors', {}).get(method)
            if error is not None:
                send({'jsonrpc': '2.0', 'id': msg['id'], 'error': error})
            else:
                send({'jsonrpc': '2.0', 'id': msg['id'],
                      'result': result_for(method)})

        # A method may also be what sets off a request of the server's own:
        # that is how it hands over an edit it worked out itself, or asks
        # something back after a notification.
        for item in SCENARIO.get('ask', {}).get(method, []):
            send({'jsonrpc': '2.0',
                  'id': item.get('id', 100000 + next_id()),
                  'method': item['method'],
                  'params': item.get('params', {})})


if __name__ == '__main__':
    main()
