"""Run local TCP and UDP tests against the isolated SOCKS collector."""

import collections
from concurrent.futures import ThreadPoolExecutor
import socket
import socketserver
import sqlite3
import struct
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from collector import Counters, SocksServer, decode_datagram, read_exact


class TestCounters:
    """Record counts in memory for network tests."""

    def __init__(self):
        """Initialize a synchronized counter."""
        self.values = collections.Counter()
        self.lock = threading.Lock()

    def add(self, domain, direction, size):
        """Accumulate forwarded bytes.

        Args:
            domain: Destination label.
            direction: Upload or download index.
            size: Byte count.
        """
        with self.lock:
            self.values[(domain, direction)] += size


def negotiate(port, command, host, target_port):
    """Open a SOCKS connection for the requested command.

    Args:
        port: SOCKS listener port.
        command: SOCKS command number.
        host: Domain or IPv4 destination.
        target_port: Destination port.
    """
    conn = socket.create_connection(("127.0.0.1", port), timeout=5)
    conn.sendall(b"\x05\x01\0")
    assert read_exact(conn, 2) == b"\x05\0"
    try:
        address = b"\x01" + socket.inet_aton(host)
    except OSError:
        address = b"\x03" + bytes([len(host)]) + host.encode()
    conn.sendall(bytes([5, command, 0]) + address + struct.pack("!H", target_port))
    reply = read_exact(conn, 10)
    assert reply[:4] == b"\x05\0\0\x01"
    return conn, struct.unpack("!H", reply[-2:])[0]


class CollectorTests(unittest.TestCase):
    """Verify forwarding and persistence using local loopback sockets."""

    def setUp(self):
        """Start a local collector and independent echo endpoints."""
        self.counters = TestCounters()
        self.proxy = SocksServer(("127.0.0.1", 0), self.counters)
        self.thread = threading.Thread(target=self.proxy.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        """Stop the local collector."""
        self.proxy.shutdown()
        self.proxy.server_close()
        self.thread.join(timeout=3)

    def test_tcp_short_connections_are_counted(self):
        """Count each short TCP connection and preserve half-close behavior."""
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()

        def serve():
            """Echo data from ten short connections."""
            with listener:
                for _ in range(10):
                    conn, _ = listener.accept()
                    with conn:
                        conn.sendall(read_exact(conn, 100))

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        for _ in range(10):
            conn, _ = negotiate(self.proxy.server_address[1], 1, "localhost", listener.getsockname()[1])
            with conn:
                conn.sendall(b"x" * 100)
                conn.shutdown(socket.SHUT_WR)
                self.assertEqual(read_exact(conn, 100), b"x" * 100)
        worker.join(timeout=5)
        deadline = time.monotonic() + 2
        while self.counters.values[("localhost", 1)] < 1000 and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.counters.values[("localhost", 0)], 1000)
        self.assertEqual(self.counters.values[("localhost", 1)], 1000)

    def test_udp_domain_is_counted(self):
        """Forward a SOCKS UDP packet and associate the reply with the domain."""
        echo = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        echo.bind(("127.0.0.1", 0))
        echo.settimeout(5)

        def serve():
            """Echo one datagram."""
            with echo:
                packet, source = echo.recvfrom(1024)
                echo.sendto(packet, source)

        threading.Thread(target=serve, daemon=True).start()
        control, relay_port = negotiate(self.proxy.server_address[1], 3, "0.0.0.0", 0)
        getaddrinfo = socket.getaddrinfo

        def resolve(host, port, **kwargs):
            """Resolve the test domain to the IPv4 echo endpoint.

            Args:
                host: Destination hostname.
                port: Destination port.
                **kwargs: Socket lookup options.
            """
            return getaddrinfo("127.0.0.1" if host == "localhost" else host, port, **kwargs)

        with patch("collector.socket.getaddrinfo", side_effect=resolve), control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.settimeout(5)
            host = b"localhost"
            payload = b"example"
            packet = b"\0\0\0\x03" + bytes([len(host)]) + host + struct.pack("!H", echo.getsockname()[1]) + payload
            client.sendto(packet, ("127.0.0.1", relay_port))
            response, _ = client.recvfrom(1024)
            self.assertEqual(decode_datagram(response)[2], payload)
        deadline = time.monotonic() + 2
        while self.counters.values[("localhost", 1)] < len(payload) and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.counters.values[("localhost", 0)], len(payload))
        self.assertEqual(self.counters.values[("localhost", 1)], len(payload))

    def test_concurrent_transfers(self):
        """Count multiple concurrent transfers without mixing byte totals."""
        class Echo(socketserver.BaseRequestHandler):
            """Serve a single fixed-size test transfer."""

            def handle(self):
                """Echo one 64 KiB request."""
                self.request.sendall(read_exact(self.request, 65536))

        class EchoServer(socketserver.ThreadingTCPServer):
            """Allow concurrent test clients."""

            daemon_threads = True
            request_queue_size = 64

        with EchoServer(("127.0.0.1", 0), Echo) as target:
            thread = threading.Thread(target=target.serve_forever, daemon=True)
            thread.start()

            def transfer(_index):
                """Send and receive one test payload.

                Args:
                    _index: Parallel transfer number.
                """
                conn, _ = negotiate(self.proxy.server_address[1], 1, "localhost", target.server_address[1])
                with conn:
                    conn.sendall(b"x" * 65536)
                    return len(read_exact(conn, 65536))

            with ThreadPoolExecutor(max_workers=16) as executor:
                self.assertEqual(sum(executor.map(transfer, range(16))), 16 * 65536)
            target.shutdown()
            thread.join(timeout=3)
        deadline = time.monotonic() + 2
        while self.counters.values[("localhost", 1)] < 16 * 65536 and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.counters.values[("localhost", 0)], 16 * 65536)
        self.assertEqual(self.counters.values[("localhost", 1)], 16 * 65536)

    def test_persistence_and_unknown(self):
        """Persist byte counts and a collector heartbeat in SQLite."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "traffic.sqlite3"
            with sqlite3.connect(path) as db:
                db.execute("CREATE TABLE dashboard_trafficminute (minute text, domain text, upload integer, download integer, UNIQUE(minute, domain))")
                db.execute("CREATE TABLE dashboard_collectorstatus (id integer PRIMARY KEY, heartbeat text)")
            counters = Counters(path)
            counters.add("Unknown", 0, 12)
            counters.flush()
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT domain, upload, download FROM dashboard_trafficminute").fetchone(), ("Unknown", 12, 0))
                self.assertIsNotNone(db.execute("SELECT heartbeat FROM dashboard_collectorstatus WHERE id=1").fetchone()[0])

    def test_database_error_retains_pending_counts(self):
        """Keep unsaved counters in memory when SQLite is unavailable."""
        counters = Counters("/nonexistent/traffic.sqlite3")
        counters.add("example.com", 0, 12)
        with self.assertLogs("traffic-collector", level="ERROR"):
            counters.flush()
        self.assertEqual(sum(value[0] for value in counters.pending.values()), 12)

    def test_fragmented_udp_is_rejected(self):
        """Reject unsupported UDP fragments rather than miscounting them."""
        with self.assertRaises(ValueError):
            decode_datagram(b"\0\0\x01\x01\x7f\0\0\x01\0\x35x")


if __name__ == "__main__":
    unittest.main()
