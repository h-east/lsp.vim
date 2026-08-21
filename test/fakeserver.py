#!/usr/bin/env python3
"""A language server that does as it is told.

What it does is read from the JSON file named by $LSP_SCENARIO:

    capabilities  what to answer "initialize" with
    notify        messages to send once "initialized" arrives, in order
    replies       result by method name, for requests that arrive later

Every message that comes in is appended to $LSP_TRACE as one JSON object per
line, so a test can check what the client sent as well as what it did with
what came back.
"""
import json
import os
import sys

SCENARIO = json.load(open(os.environ['LSP_SCENARIO']))
TRACE = open(os.environ.get('LSP_TRACE', os.devnull), 'w')


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
        elif 'id' in msg:
            # Anything else that expects an answer gets what the scenario
            # holds for it, and null when it holds nothing.
            send({'jsonrpc': '2.0', 'id': msg['id'],
                  'result': SCENARIO.get('replies', {}).get(method)})


if __name__ == '__main__':
    main()
