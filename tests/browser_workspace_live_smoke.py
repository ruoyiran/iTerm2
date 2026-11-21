#!/usr/bin/env python3
"""Exercise the real CLI/MCP against the local native browser fixture.

Launch iTerm2 with an isolated -suite and serve browser_automation_native_fixture.html
as index.html on loopback. Set IT2_SUITE / IT2_APP_PATH for that candidate, then run
with --session (a concrete primary terminal ID) and --url. No agent config is edited.
"""
import argparse
import base64
import json
import select
import struct
import subprocess
from pathlib import Path
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--it2', type=Path, default=Path(__file__).resolve().parents[1] / 'it2cli/bin/it2')
    parser.add_argument('--session', required=True)
    parser.add_argument('--url', required=True)
    parser.add_argument('--browser', help='Reuse a disposable fixture browser; otherwise create and close one')
    parser.add_argument('--screenshot', type=Path)
    args = parser.parse_args()
    assert urlsplit(args.url).hostname in ('127.0.0.1', 'localhost'), 'Use a loopback fixture only'

    def cli(action, *options, expect_error=None):
        result = subprocess.run([str(args.it2), 'browser', action, '--session', args.session, *options],
                                capture_output=True, text=True, timeout=135)
        assert not result.stderr, result.stderr
        value = json.loads(result.stdout)
        if expect_error:
            assert result.returncode != 0 and value['error']['code'] == expect_error, value
        else:
            assert result.returncode == 0 and value['ok'], value
        return value

    owned = args.browser is None
    browser = args.browser or cli('tabs', '--operation', 'create', '--url', args.url)['result']['browser_session_id']
    target = ['--browser-session', browser]
    checks = []
    process = None
    try:
        cli('tabs', *target, '--operation', 'select')
        cli('navigate', *target, '--url', args.url)
        cli('wait', *target, '--state', 'ready')
        page = cli('snapshot', *target)['result']
        assert page['url'] == args.url and page['title'] == 'Native browser fixture', 'Unexpected target document'
        node = next(n for n in page['nodes'] if n.get('name') == 'Name' and n.get('role') == 'textbox')
        cli('fill', *target, '--generation', page['generation'], '--ref', node['ref'], '--value', 'Agent verified')
        page = cli('snapshot', *target)['result']
        assert any(n.get('value') == 'Agent verified' for n in page['nodes'])
        node = next(n for n in page['nodes'] if n.get('name') == 'Go' and n.get('role') == 'button')
        cli('click', *target, '--generation', page['generation'], '--ref', node['ref'])
        page = cli('snapshot', *target)['result']
        assert any(n.get('name') == 'Clicked' for n in page['nodes'])
        checks.append('cli_snapshot_fill_click')
        cli('click', *target, '--generation', 'expired-generation', '--ref', node['ref'], expect_error='stale_reference')
        checks.append('cli_stale_reference')
        file_node = next(n for n in page['nodes'] if n.get('input_type') == 'file')
        cli('fill', *target, '--generation', page['generation'], '--ref', file_node['ref'], '--value', 'test', expect_error='unsupported')
        checks.append('cli_native_picker_rejected')
        isolated = cli('evaluate', *target, '--expression', 'return typeof window.pageSecret;')['result']
        assert isolated['value'] == 'undefined', isolated
        checks.append('cli_evaluate_isolated')

        process = subprocess.Popen([str(args.it2), 'browser', 'mcp', '--session', args.session],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, bufsize=1)

        def send(value):
            process.stdin.write(json.dumps(value) + '\n')
            process.stdin.flush()

        def receive(expected_id):
            assert select.select([process.stdout], [], [], 30)[0], 'MCP response deadline exceeded'
            line = process.stdout.readline()
            assert line, 'MCP terminated without a response'
            value = json.loads(line)
            assert value.get('id') == expected_id and 'result' in value, value
            return value['result']

        def tool(identifier, name, arguments=None):
            send({'jsonrpc': '2.0', 'id': identifier, 'method': 'tools/call',
                  'params': {'name': name, 'arguments': arguments or {}}})
            value = receive(identifier)
            assert not value.get('isError'), value
            data = json.loads(value['content'][0]['text'])
            assert data['ok'], data
            return data, value

        send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
            'protocolVersion': '2025-11-25', 'capabilities': {},
            'clientInfo': {'name': 'native-workspace-smoke', 'version': '1'}}})
        assert receive(1)['serverInfo']['name'] == 'it2-browser'
        send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
        assert len(receive(2)['tools']) == 12
        data, _ = tool(3, 'browser_snapshot', {'browser_session_id': browser})
        assert data['result']['url'] == args.url
        checks.append('mcp_native_snapshot')
        _, value = tool(4, 'browser_screenshot', {'browser_session_id': browser})
        png = base64.b64decode(value['content'][1]['data'])
        assert value['content'][1]['mimeType'] == 'image/png' and png.startswith(b'\x89PNG\r\n\x1a\n')
        width, height = struct.unpack('>II', png[16:24])
        assert width > 0 and height > 0
        if args.screenshot:
            args.screenshot.write_bytes(png)
        checks.append('mcp_native_png')
        send({'jsonrpc': '2.0', 'id': 5, 'method': 'tools/call', 'params': {
            'name': 'browser_wait', 'arguments': {'browser_session_id': browser,
                'selector': '#never-created', 'state': 'visible', 'timeout_ms': 120000}}})
        tool(6, 'browser_capabilities')
        send({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 5}})
        data, _ = tool(7, 'browser_snapshot', {'browser_session_id': browser})
        assert data['result']['url'] == args.url
        checks.append('mcp_cancel_releases_browser_queue')
        process.stdin.close()
        process.wait(timeout=15)
        assert process.returncode == 0 and not process.stderr.read()
        print(json.dumps({'ok': True, 'browser_session_id': browser, 'checks': checks,
                          'viewport_png': {'width': width, 'height': height}}))
    finally:
        if process:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=15)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream and not stream.closed:
                    stream.close()
        if owned:
            cli('tabs', *target, '--operation', 'close')


if __name__ == '__main__':
    main()
