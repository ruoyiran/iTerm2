"""Native, explicitly scoped browser automation over iTerm2's Python API.

DOM input is untrusted. Native dialogs, clipboard, downloads, drag/drop, file
inputs, and cross-origin frames are not supported. ``async_evaluate`` executes
an async function body in an isolated world; return a JSON value explicitly.
Browser operations cannot run inside an API transaction. Cancellation prevents
later native dispatch and suppresses late results; JavaScript already dispatched
cannot be interrupted or have its effects retracted.
"""
from __future__ import annotations

import asyncio
import json
import uuid
from typing import TYPE_CHECKING, Any

from . import rpc

if TYPE_CHECKING:
    from .connection import Connection


class BrowserError(rpc.RPCException):
    """A browser automation failure with a stable, locale-independent code."""
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class Browser:
    """A browser client bound to a primary tab through its origin session ID."""
    def __init__(self, connection: Connection, origin_session_id: str,
                 browser_session_id: str | None = None):
        if not origin_session_id or origin_session_id in ('active', 'all'):
            raise ValueError('An explicit origin session ID is required')
        if browser_session_id in ('active', 'all'):
            raise ValueError('An explicit browser session ID is required')
        self.connection = connection
        self.origin_session_id = origin_session_id
        self.browser_session_id = browser_session_id
        self.capabilities: list[str] = []

    async def async_request(self, action: str, arguments: dict[str, Any] | None = None,
                            timeout_ms: int = 30000,
                            request_id: str | None = None) -> dict[str, Any]:
        """Dispatch one action; cancelling the coroutine cancels its native request."""
        if type(timeout_ms) is not int or not 1 <= timeout_ms <= 120000:
            raise ValueError('timeout_ms must be between 1 and 120000')
        arguments = {} if arguments is None else arguments
        if not isinstance(arguments, dict):
            raise ValueError('arguments must be an object')
        json.dumps(arguments, allow_nan=False)
        request_id = request_id or str(uuid.uuid4())
        try:
            response = await rpc.async_browser_request(
                self.connection, self.origin_session_id, self.browser_session_id,
                action, arguments, timeout_ms, request_id)
        except asyncio.CancelledError:
            # Send on the same authenticated connection. Keep the task alive until
            # it finishes; a cancelled waiter must not strand a permission prompt.
            task = asyncio.create_task(rpc.async_browser_request(
                self.connection, self.origin_session_id, None, 'cancel',
                {'request_id': request_id}, 1000))
            try:
                await asyncio.shield(task)
            except (asyncio.CancelledError, Exception):
                pass
            raise
        if not response.HasField('browser_response'):
            raise BrowserError('unsupported', 'This iTerm2 version does not support browser automation')
        browser = response.browser_response
        self.capabilities = list(browser.capabilities)
        if browser.error_code:
            raise BrowserError(browser.error_code, browser.error_message)
        result = json.loads(browser.result_json)
        if not isinstance(result, dict):
            raise BrowserError('internal_error', 'The browser returned a malformed response')
        if browser.HasField('png_data'):
            result['png_data'] = browser.png_data
        return result

    async def async_tabs(self, operation='list', url=None, **kwargs):
        args = {'operation': operation}
        if url is not None:
            args['url'] = url
        return await self.async_request('tabs', args, **kwargs)

    async def async_navigate(self, url=None, operation='navigate', **kwargs):
        args = {'operation': operation}
        if url is not None:
            args['url'] = url
        return await self.async_request('navigate', args, **kwargs)

    async def async_snapshot(self, max_nodes=1000, **kwargs):
        return await self.async_request('snapshot', {'max_nodes': max_nodes}, **kwargs)

    async def async_click(self, generation, ref, **kwargs):
        return await self.async_request('click', {'generation': generation, 'ref': ref}, **kwargs)

    async def async_fill(self, generation, ref, value, **kwargs):
        return await self.async_request('fill', {'generation': generation, 'ref': ref, 'value': value}, **kwargs)

    async def async_press_key(self, generation, key, ref=None, **kwargs):
        args = {'generation': generation, 'key': key}
        if ref is not None:
            args['ref'] = ref
        return await self.async_request('press_key', args, **kwargs)

    async def async_scroll(self, generation, x=0, y=0, ref=None, **kwargs):
        args = {'generation': generation, 'x': x, 'y': y}
        if ref is not None:
            args['ref'] = ref
        return await self.async_request('scroll', args, **kwargs)

    async def async_wait(self, selector=None, state='ready', generation=None, **kwargs):
        args = {'state': state}
        if selector is not None:
            args['selector'] = selector
        if generation is not None:
            args['generation'] = generation
        return await self.async_request('wait', args, **kwargs)

    async def async_screenshot(self, **kwargs):
        return await self.async_request('screenshot', {}, **kwargs)

    async def async_evaluate(self, expression, **kwargs):
        return await self.async_request('evaluate', {'expression': expression}, **kwargs)

    async def async_cancel(self, request_id):
        return await self.async_request('cancel', {'request_id': request_id})
