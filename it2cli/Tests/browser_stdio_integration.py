#!/usr/bin/env python3
"""Hermetic CLI/MCP smoke tests over real stdio and a fake local Unix WebSocket.

Uses a minimal protobuf wire reader so no Python package installation is needed.
Run after swift build: python3 Tests/browser_stdio_integration.py
"""
import base64
import json
import os
from pathlib import Path
import select
import shutil
import socket
import struct
import subprocess
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('IT2_TEST_BIN_DIR', ROOT / '.build/debug'))


def varint(number):
    data = bytearray()
    while number > 127:
        data.append((number & 127) | 128)
        number >>= 7
    data.append(number)
    return bytes(data)


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    if isinstance(value, str):
        value = value.encode()
    return varint((number << 3) | 2) + varint(len(value)) + value


def fields(data):
    index = 0
    result = {}

    def read_int():
        nonlocal index
        value = shift = 0
        while True:
            byte = data[index]
            index += 1
            value |= (byte & 127) << shift
            if not byte & 128:
                return value
            shift += 7

    while index < len(data):
        tag = read_int()
        if tag & 7 == 0:
            value = read_int()
        elif tag & 7 == 2:
            length = read_int()
            value = data[index:index + length]
            index += length
        else:
            raise AssertionError('Unexpected wire type')
        result[tag >> 3] = value
    return result


def read_exact(connection, count):
    value = b''
    while len(value) < count:
        chunk = connection.recv(count - len(value))
        if not chunk:
            raise EOFError()
        value += chunk
    return value


def read_frame(connection):
    opcode, length = read_exact(connection, 2)
    if opcode & 15 == 8:
        raise EOFError()
    masked = length & 128
    length &= 127
    if length == 126:
        length = struct.unpack('>H', read_exact(connection, 2))[0]
    elif length == 127:
        length = struct.unpack('>Q', read_exact(connection, 8))[0]
    mask = read_exact(connection, 4) if masked else None
    payload = read_exact(connection, length)
    return bytes(value ^ mask[i % 4] for i, value in enumerate(payload)) if mask else payload


def send_frame(connection, payload):
    length = len(payload)
    header = bytes([0x82, length]) if length < 126 else bytes([0x82, 126]) + struct.pack('>H', length)
    connection.sendall(header + payload)


class LocalApp:
    def __init__(self):
        self.suite = 'it2test-' + uuid.uuid4().hex[:8]
        self.directory = Path.home() / 'Library/Application Support' / self.suite
        self.path = self.directory / 'private/socket'
        self.path.parent.mkdir(parents=True)
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.bind(str(self.path))
        self.socket.listen()
        self.requests = []
        self.cancelled = threading.Event()
        self.accepted = threading.Event()
        self.stopped = False
        self.active = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def environment(self):
        environment = dict(os.environ)
        for key in ['TMUX', 'TMUX_PANE', 'ITERM2_KEY', 'IT2_SOCK']:
            environment.pop(key, None)
        environment.update(IT2_SUITE=self.suite, ITERM2_COOKIE='fake-cookie', TERM_SESSION_ID='w0t0p0:caller-origin')
        return environment

    def serve(self):
        while not self.stopped:
            try:
                connection, _ = self.socket.accept()
                self.active.append(connection)
                self.accepted.set()
                header = b''
                while not header.endswith(b'\r\n\r\n'):
                    header += read_exact(connection, 1)
                connection.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
                while True:
                    message = fields(read_frame(connection))
                    request = fields(message[137])
                    action = request[3].decode()
                    arguments = json.loads(request.get(4, b'{}'))
                    self.requests.append((request, arguments))
                    if action == 'wait':
                        continue
                    if action == 'cancel':
                        self.cancelled.set()
                        result = {'cancelled': True}
                    elif action == 'tabs':
                        result = {'tabs': []}
                    elif action == 'evaluate':
                        response = field(2, 'javascript_error') + field(3, 'Localized detail')
                        send_frame(connection, field(1, message[1]) + field(137, response))
                        continue
                    else:
                        result = {'browser_session_id': 'browser-id', 'format': 'png'}
                    response = field(1, json.dumps(result)) + field(5, 'cancel')
                    if action == 'screenshot':
                        response += field(4, b'\x89PNG\r\n\x1a\n')
                    send_frame(connection, field(1, message[1]) + field(137, response))
            except (EOFError, OSError):
                pass
            finally:
                if 'connection' in locals():
                    connection.close()

    def close(self):
        self.stopped = True
        for connection in self.active:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.socket.close()
        shutil.rmtree(self.directory)


class BrowserStdioTests(unittest.TestCase):
    def setUp(self):
        self.app = LocalApp()

    def tearDown(self):
        self.app.close()

    def cli(self, *arguments):
        return subprocess.run([str(BIN / 'it2'), 'browser', *arguments], env=self.app.environment(), capture_output=True, text=True, timeout=10)

    def test_cli_json_origin_screenshot_and_error(self):
        result = self.cli('tabs')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['result'], {'tabs': []})
        self.assertEqual(self.app.requests[0][0][1], b'caller-origin')
        shot = self.cli('screenshot', '--browser-session', 'browser-id')
        self.assertEqual(base64.b64decode(json.loads(shot.stdout)['png_data']), b'\x89PNG\r\n\x1a\n')
        error = self.cli('evaluate', '--expression', 'throw Error("test")')
        self.assertNotEqual(error.returncode, 0)
        self.assertEqual(json.loads(error.stdout)['error']['code'], 'javascript_error')
        self.assertEqual(error.stderr, '')

    def test_cli_deadline_sends_cancel(self):
        result = self.cli('wait', '--state', 'ready', '--timeout-ms', '10')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['error']['code'], 'timeout')
        self.assertTrue(self.app.cancelled.wait(5))

    def test_mcp_stdio_launcher_handshake_image_and_cancellation(self):
        process = subprocess.Popen([str(BIN / 'it2'), 'browser', 'mcp'], env=self.app.environment(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)

        def send(value):
            process.stdin.write(json.dumps(value) + '\n')
            process.stdin.flush()

        def receive():
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'Timed out waiting for MCP stdout')
            return json.loads(process.stdout.readline())

        send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}}})
        self.assertEqual(receive()['result']['serverInfo']['name'], 'it2-browser')
        self.assertFalse(self.app.accepted.is_set(), 'Initialization must not connect or prompt')
        send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
        self.assertEqual(len(receive()['result']['tools']), 12)
        send({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'browser_screenshot'}})
        content = receive()['result']['content']
        self.assertEqual(content[1]['type'], 'image')
        self.assertEqual(content[1]['mimeType'], 'image/png')
        send({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'browser_wait', 'arguments': {'state': 'ready'}}})
        deadline = time.monotonic() + 5
        while not any(request[0].get(3) == b'wait' for request in self.app.requests):
            self.assertLess(time.monotonic(), deadline)
            threading.Event().wait(0.01)
        send({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 4}})
        self.assertTrue(self.app.cancelled.wait(5), 'Cancellation must reach the same app connection')
        send({'jsonrpc': '2.0', 'id': 5, 'method': 'tools/call', 'params': {'name': 'browser_capabilities'}})
        self.assertEqual(receive()['id'], 5, 'Cancelled MCP requests must not emit a response')
        process.stdin.close()
        process.wait(timeout=10)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(process.stderr.read(), '')
        process.stdout.close(); process.stderr.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
