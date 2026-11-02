"""Forward SOCKS5 traffic and aggregate bytes without writing on the forwarding path."""

import argparse
import collections
import contextlib
import datetime
import ipaddress
import logging
import selectors
import signal
import socket
import socketserver
import sqlite3
import struct
import threading
import time
from pathlib import Path

from dashboard.constants import SOURCE_ORIGINAL, SOURCE_PREVIEW

LOGGER = logging.getLogger("traffic-collector")
UNKNOWN = "Unknown"
MAX_PENDING = 4096
FLUSH_SECONDS = 1
UDP_TARGET_LIMIT = 256
UDP_IDLE_SECONDS = 60
MAX_CONNECTIONS = 64


def read_exact(conn, size):
    """Read exactly size bytes or raise EOFError.

    Args:
        conn: Connected socket.
        size: Number of bytes to read.
    """
    data = bytearray()
    while len(data) < size:
        part = conn.recv(size - len(data))
        if not part:
            raise EOFError("Connection closed")
        data.extend(part)
    return bytes(data)


def destination_label(host):
    """Return the hostname or Unknown when the destination is an IP address.

    Args:
        host: SOCKS destination host.
    """
    try:
        ipaddress.ip_address(host)
        return UNKNOWN
    except ValueError:
        name = host.rstrip(".").lower()
        return name if name and len(name) <= 253 else UNKNOWN


def read_address(conn, atyp):
    """Decode a SOCKS address from a stream.

    Args:
        conn: Connected socket.
        atyp: SOCKS address type.
    """
    if atyp == 1:
        host = socket.inet_ntop(socket.AF_INET, read_exact(conn, 4))
    elif atyp == 3:
        host = read_exact(conn, read_exact(conn, 1)[0]).decode("ascii")
    elif atyp == 4:
        host = socket.inet_ntop(socket.AF_INET6, read_exact(conn, 16))
    else:
        raise ValueError("Unsupported address type")
    return host, struct.unpack("!H", read_exact(conn, 2))[0]


def decode_datagram(data):
    """Decode an unfragmented SOCKS UDP datagram.

    Args:
        data: Complete SOCKS UDP packet.
    """
    if len(data) < 4 or data[:3] != b"\0\0\0":
        raise ValueError("Invalid or fragmented datagram")
    atyp = data[3]
    offset = 4
    if atyp == 1:
        length, family = 4, socket.AF_INET
    elif atyp == 4:
        length, family = 16, socket.AF_INET6
    elif atyp == 3:
        if len(data) <= offset:
            raise ValueError("Missing hostname")
        length, family = data[offset], None
        offset += 1
    else:
        raise ValueError("Unsupported address type")
    if not length or len(data) < offset + length + 2:
        raise ValueError("Truncated address")
    raw = data[offset:offset + length]
    host = socket.inet_ntop(family, raw) if family else raw.decode("ascii")
    offset += length
    port = struct.unpack("!H", data[offset:offset + 2])[0]
    return host, port, data[offset + 2:]


def encode_datagram(address, payload):
    """Wrap a UDP response in a SOCKS header.

    Args:
        address: Source socket address.
        payload: Received datagram payload.
    """
    ip = ipaddress.ip_address(address[0])
    atyp = b"\x01" if ip.version == 4 else b"\x04"
    return b"\0\0\0" + atyp + ip.packed + struct.pack("!H", address[1]) + payload


class Counters:
    """Aggregate pending samples in memory and periodically persist them."""

    def __init__(self, database, source=SOURCE_PREVIEW):
        """Initialize an aggregator for a database.

        Args:
            database: SQLite database path initialized by the dashboard.
            source: Original or isolated preview node.
        """
        self.database = str(database)
        self.source = source
        self.pending = collections.defaultdict(lambda: [0, 0])
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def add(self, domain, direction, size):
        """Accumulate bytes in the current UTC minute.

        Args:
            domain: Destination domain or Unknown.
            direction: Zero for upload or one for download.
            size: Successfully forwarded byte count.
        """
        minute = datetime.datetime.now(datetime.timezone.utc).replace(second=0, microsecond=0).strftime("%Y-%m-%d %H:%M:%S")
        with self.lock:
            key = (minute, domain)
            if key not in self.pending and len(self.pending) >= MAX_PENDING:
                key = (minute, UNKNOWN)
            self.pending[key][direction] += size

    def flush(self):
        """Persist pending data, retaining it in memory when the database fails."""
        with self.lock:
            pending, self.pending = self.pending, collections.defaultdict(lambda: [0, 0])
        try:
            with sqlite3.connect(self.database, timeout=10) as db:
                db.executemany(
                    "INSERT INTO dashboard_trafficminute (minute, domain, source, upload, download) VALUES (?, ?, ?, ?, ?) "
                    "ON CONFLICT(source, minute, domain) DO UPDATE SET upload = upload + excluded.upload, download = download + excluded.download",
                    [(minute, domain, self.source, *counts) for (minute, domain), counts in pending.items()],
                )
                now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                db.execute("INSERT INTO dashboard_collectorstatus (source, heartbeat) VALUES (?, ?) ON CONFLICT(source) DO UPDATE SET heartbeat = excluded.heartbeat", (self.source, now))
        except sqlite3.Error:
            LOGGER.exception("Traffic data could not be saved")
            with self.lock:
                for key, counts in pending.items():
                    self.pending[key][0] += counts[0]
                    self.pending[key][1] += counts[1]

    def run(self):
        """Flush until shutdown, then make one final persistence attempt."""
        while not self.stop_event.wait(FLUSH_SECONDS):
            self.flush()
        self.flush()


class SocksServer(socketserver.ThreadingTCPServer):
    """Accept only local connections from the isolated Xray instance."""

    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 128

    def __init__(self, address, counters):
        """Bind the proxy to its local address.

        Args:
            address: Listening host and port.
            counters: Shared traffic accumulator.
        """
        self.counters = counters
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        super().__init__(address, SocksHandler)

    def process_request(self, request, client_address):
        """Limit the number of simultaneous preview connections.

        Args:
            request: Accepted socket.
            client_address: Remote socket address.
        """
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        """Release a connection slot when its handler ends.

        Args:
            request: Accepted socket.
            client_address: Remote socket address.
        """
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class SocksHandler(socketserver.BaseRequestHandler):
    """Handle TCP CONNECT and UDP ASSOCIATE requests."""

    def handle(self):
        """Negotiate SOCKS5 and relay one request."""
        client = self.request
        client.settimeout(10)
        try:
            version, count = read_exact(client, 2)
            methods = read_exact(client, count)
            if version != 5 or 0 not in methods:
                client.sendall(b"\x05\xff")
                return
            client.sendall(b"\x05\x00")
            version, command, reserved, atyp = read_exact(client, 4)
            if version != 5 or reserved != 0:
                raise ValueError("Invalid request")
            host, port = read_address(client, atyp)
            if command == 1:
                self.connect(client, host, port)
            elif command == 3:
                self.udp_associate(client)
            else:
                client.sendall(b"\x05\x07\x00\x01\0\0\0\0\0\0")
        except (OSError, EOFError, UnicodeError, ValueError):
            LOGGER.debug("SOCKS request ended", exc_info=True)

    def connect(self, client, host, port):
        """Forward a TCP connection and count successfully forwarded bytes.

        Args:
            client: Local SOCKS client socket.
            host: Requested destination.
            port: Requested destination port.
        """
        try:
            remote = socket.create_connection((host, port), timeout=10)
        except OSError:
            client.sendall(b"\x05\x05\x00\x01\0\0\0\0\0\0")
            return
        with remote:
            client.settimeout(None)
            remote.settimeout(None)
            client.sendall(b"\x05\x00\x00\x01\x7f\0\0\x01\0\0")
            domain = destination_label(host)

            def pump(source, target, direction):
                """Copy one direction until EOF and half-close its peer.

                Args:
                    source: Receiving socket.
                    target: Sending socket.
                    direction: Counter direction.
                """
                try:
                    while True:
                        data = source.recv(65536)
                        if not data:
                            break
                        view = memoryview(data)
                        while view:
                            sent = target.send(view)
                            if not sent:
                                return
                            self.server.counters.add(domain, direction, sent)
                            view = view[sent:]
                except OSError:
                    pass
                finally:
                    with contextlib.suppress(OSError):
                        target.shutdown(socket.SHUT_WR)

            worker = threading.Thread(target=pump, args=(client, remote, 0), daemon=True)
            worker.start()
            pump(remote, client, 1)
            worker.join()

    def udp_associate(self, control):
        """Forward UDP using a separate socket per destination.

        Args:
            control: SOCKS TCP association socket.
        """
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as relay, selectors.DefaultSelector() as selector:
            relay.bind(("127.0.0.1", 0))
            relay.setblocking(False)
            control.setblocking(False)
            selector.register(control, selectors.EVENT_READ, None)
            selector.register(relay, selectors.EVENT_READ, None)
            control.sendall(b"\x05\x00\x00\x01\x7f\0\0\x01" + struct.pack("!H", relay.getsockname()[1]))
            client_address = None
            targets = {}
            try:
                while True:
                    for key, _ in selector.select(timeout=1):
                        if key.fileobj is control:
                            if not control.recv(1):
                                return
                        elif key.fileobj is relay:
                            data, source = relay.recvfrom(65535)
                            if source[0] != self.client_address[0] or (client_address and source != client_address):
                                continue
                            client_address = source
                            try:
                                host, port, payload = decode_datagram(data)
                                if (host, port) not in targets:
                                    if len(targets) >= UDP_TARGET_LIMIT:
                                        continue
                                    info = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)[0]
                                    target = socket.socket(info[0], socket.SOCK_DGRAM)
                                    target.connect(info[4])
                                    target.setblocking(False)
                                    targets[(host, port)] = [target, time.monotonic()]
                                    selector.register(target, selectors.EVENT_READ, (host, port))
                                target, _ = targets[(host, port)]
                                sent = target.send(payload)
                                self.server.counters.add(destination_label(host), 0, sent)
                                targets[(host, port)][1] = time.monotonic()
                            except (OSError, ValueError, UnicodeError):
                                continue
                        else:
                            host, port = key.data
                            try:
                                data, source = key.fileobj.recvfrom(65535)
                                if client_address:
                                    relay.sendto(encode_datagram(source, data), client_address)
                                    self.server.counters.add(destination_label(host), 1, len(data))
                                targets[(host, port)][1] = time.monotonic()
                            except OSError:
                                continue
                    for destination, (target, last_used) in list(targets.items()):
                        if time.monotonic() - last_used > UDP_IDLE_SECONDS:
                            selector.unregister(target)
                            target.close()
                            del targets[destination]
            finally:
                for target, _ in targets.values():
                    target.close()


def main():
    """Run a loopback-only collector using an initialized dashboard database."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--source", choices=(SOURCE_PREVIEW, SOURCE_ORIGINAL), default=SOURCE_PREVIEW)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    counters = Counters(args.database, args.source)
    counters.thread.start()
    with SocksServer(("127.0.0.1", args.port), counters) as server:
        def stop(_signum, _frame):
            """Stop the server without deadlocking its main thread.

            Args:
                _signum: Signal number.
                _frame: Interrupted stack frame.
            """
            threading.Thread(target=server.shutdown, daemon=True).start()

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            server.serve_forever()
        finally:
            counters.stop_event.set()
            counters.thread.join(timeout=15)


if __name__ == "__main__":
    main()
