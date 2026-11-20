"""Focused browser SDK contract and sidebar discovery tests."""
import asyncio
import json
import unittest
from unittest.mock import patch

from iterm2 import api_pb2
from iterm2.browser import Browser, BrowserError
from iterm2.window import Window


class BrowserTests(unittest.IsolatedAsyncioTestCase):
    async def test_typed_request_and_png_payload(self):
        response = api_pb2.ServerOriginatedMessage()
        response.browser_response.result_json = '{"format":"png"}'
        response.browser_response.png_data = b'PNG'
        with patch('iterm2.rpc._async_call', return_value=response) as call:
            result = await Browser(None, 'origin', 'browser').async_screenshot()
        request = call.call_args.args[1].browser_request
        self.assertEqual(request.origin_session_id, 'origin')
        self.assertEqual(request.browser_session_id, 'browser')
        self.assertEqual(request.action, 'screenshot')
        self.assertEqual(result['png_data'], b'PNG')

    async def test_error_is_structural(self):
        response = api_pb2.ServerOriginatedMessage()
        response.browser_response.error_code = 'stale_reference'
        response.browser_response.error_message = 'translated reason'
        with patch('iterm2.rpc._async_call', return_value=response):
            with self.assertRaises(BrowserError) as caught:
                await Browser(None, 'origin', 'browser').async_click('generation', 'ref')
        self.assertEqual(caught.exception.code, 'stale_reference')

    async def test_invalid_origin_rejected_before_dispatch(self):
        with self.assertRaises(ValueError):
            Browser(None, 'active')

    async def test_nonfinite_json_rejected(self):
        with self.assertRaises(ValueError):
            await Browser(None, 'origin', 'browser').async_request('scroll', {'x': float('nan')})

    async def test_coroutine_cancellation_sends_native_cancel(self):
        requests = []
        started = asyncio.Event()
        async def dispatch(connection, request):
            requests.append(request)
            if request.browser_request.action == 'cancel':
                response = api_pb2.ServerOriginatedMessage()
                response.browser_response.result_json = '{"cancelled":true}'
                return response
            started.set()
            await asyncio.Event().wait()
        with patch('iterm2.rpc._async_call', side_effect=dispatch):
            task = asyncio.create_task(Browser(None, 'origin', 'browser').async_request('snapshot', request_id='known'))
            await started.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[1].browser_request.action, 'cancel')
        self.assertEqual(json.loads(requests[1].browser_request.arguments_json), {'request_id': 'known'})

    def test_sidebar_sessions_are_discoverable_without_changing_split_sessions(self):
        window = api_pb2.ListSessionsResponse.Window(window_id='window')
        tab = window.tabs.add(tab_id='tab')
        tab.root.links.add().session.unique_identifier = 'primary'
        tab.sidebar_sessions.add(unique_identifier='browser', title='Browser')
        parsed = Window.create_from_proto(None, window)
        self.assertEqual([s.session_id for s in parsed.tabs[0].sessions], ['primary'])
        self.assertEqual([s.session_id for s in parsed.tabs[0].sidebar_sessions], ['browser'])
        self.assertEqual([s.session_id for s in parsed.tabs[0].all_sessions], ['primary', 'browser'])


if __name__ == '__main__':
    unittest.main()
