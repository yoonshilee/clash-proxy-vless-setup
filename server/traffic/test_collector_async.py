"""Exercise the asynchronous collector with real local sockets."""

import asyncio
import socket
import threading
import time
from types import SimpleNamespace

from collector import read_exact
from collector_async import SocksServer
from test_collector import CollectorTests, TestCounters, negotiate


class AsyncCollectorTests(CollectorTests):
    """Run the shared SOCKS tests against the asynchronous implementation."""

    def setUp(self):
        """Start an asynchronous collector on an isolated event loop."""
        self.counters = TestCounters()
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        self.handler = SocksServer(self.counters)

        async def start():
            """Bind a local test listener."""
            return await asyncio.start_server(self.handler.handle, "127.0.0.1", 0, backlog=256)

        self.server = asyncio.run_coroutine_threadsafe(start(), self.loop).result(timeout=5)
        self.proxy = SimpleNamespace(server_address=self.server.sockets[0].getsockname())

    def tearDown(self):
        """Stop the listener and its active tasks."""
        async def stop():
            """Close all asynchronous test resources."""
            self.server.close()
            tasks = list(self.handler.tasks)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await self.server.wait_closed()

        asyncio.run_coroutine_threadsafe(stop(), self.loop).result(timeout=10)
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(timeout=5)
        self.loop.close()

    def test_three_hundred_simultaneous_connections(self):
        """Keep 300 streams active and count each byte in both directions."""
        async def echo(reader, writer):
            """Echo data until the test client disconnects.

            Args:
                reader: Client stream reader.
                writer: Client stream writer.
            """
            try:
                while data := await reader.read(4096):
                    writer.write(data)
                    await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        async def start_echo():
            """Start an asynchronous echo target."""
            return await asyncio.start_server(echo, "127.0.0.1", 0, backlog=256)

        target = asyncio.run_coroutine_threadsafe(start_echo(), self.loop).result(timeout=5)
        port = target.sockets[0].getsockname()[1]
        connections = []
        try:
            for _ in range(300):
                conn, _ = negotiate(self.proxy.server_address[1], 1, "127.0.0.1", port)
                connections.append(conn)
            for conn in connections:
                conn.sendall(b"x" * 16)
            for conn in connections:
                self.assertEqual(read_exact(conn, 16), b"x" * 16)
            deadline = time.monotonic() + 5
            while self.counters.values[("Unknown", 1)] < 4800 and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertEqual(self.counters.values[("Unknown", 0)], 4800)
            self.assertEqual(self.counters.values[("Unknown", 1)], 4800)
        finally:
            for conn in connections:
                conn.close()

            async def stop_echo():
                """Stop the echo listener after client cleanup."""
                target.close()
                await target.wait_closed()
                await asyncio.sleep(.1)

            asyncio.run_coroutine_threadsafe(stop_echo(), self.loop).result(timeout=5)
