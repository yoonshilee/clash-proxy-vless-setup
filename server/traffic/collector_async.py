"""Count SOCKS5 traffic with bounded asynchronous TCP and UDP forwarding."""

import argparse
import asyncio
import contextlib
import ipaddress
import logging
import signal
import socket
import struct
import time
from pathlib import Path

from collector import Counters, decode_datagram, destination_label, encode_datagram
from dashboard.constants import SOURCE_ORIGINAL, SOURCE_PREVIEW

LOGGER = logging.getLogger("traffic-collector-async")
MAX_CONNECTIONS = 1024
MAX_UDP_TARGETS = 256
MAX_UDP_TASKS = 1024
UDP_IDLE_SECONDS = 60
HANDSHAKE_SECONDS = 10
BUFFER_SIZE = 65536


async def read_address(reader, atyp):
    """Decode a SOCKS destination from a stream.

    Args:
        reader: Asynchronous stream reader.
        atyp: SOCKS address type.
    """
    if atyp == 1:
        host = socket.inet_ntop(socket.AF_INET, await reader.readexactly(4))
    elif atyp == 4:
        host = socket.inet_ntop(socket.AF_INET6, await reader.readexactly(16))
    elif atyp == 3:
        length = (await reader.readexactly(1))[0]
        if not length:
            raise ValueError("Empty destination")
        host = (await reader.readexactly(length)).decode("ascii")
    else:
        raise ValueError("Unsupported address type")
    port = struct.unpack("!H", await reader.readexactly(2))[0]
    return host, port


def health_destination(host, port, health_port):
    """Identify the reserved local health endpoint.

    Args:
        host: Requested destination.
        port: Requested port.
        health_port: Reserved health port, or None.
    """
    if not health_port or port != health_port:
        return False
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class RemoteDatagram(asyncio.DatagramProtocol):
    """Associate a UDP destination socket with its original domain."""

    def __init__(self, association, host, port):
        """Remember the originating association and destination.

        Args:
            association: Parent SOCKS UDP association.
            host: Requested destination host.
            port: Requested destination port.
        """
        self.association = association
        self.host = host
        self.port = port
        self.transport = None
        self.last_used = time.monotonic()

    def connection_made(self, transport):
        """Store the connected UDP transport.

        Args:
            transport: Asynchronous datagram transport.
        """
        self.transport = transport

    def datagram_received(self, data, address):
        """Relay one response and count its payload.

        Args:
            data: Received payload.
            address: Source socket address.
        """
        self.last_used = time.monotonic()
        if not self.association.client_address or self.association.closed:
            return
        try:
            self.association.transport.sendto(encode_datagram(address, data), self.association.client_address)
            if not health_destination(self.host, self.port, self.association.health_port):
                self.association.counters.add(destination_label(self.host), 1, len(data))
        except (OSError, ValueError):
            LOGGER.debug("UDP response could not be relayed", exc_info=True)


class UDPAssociation(asyncio.DatagramProtocol):
    """Forward one SOCKS UDP association using per-destination sockets."""

    def __init__(self, client_ip, counters, health_port):
        """Initialize a bounded association.

        Args:
            client_ip: Address of the SOCKS control connection.
            counters: Shared traffic accumulator.
            health_port: Reserved local health port, or None.
        """
        self.client_ip = client_ip
        self.counters = counters
        self.health_port = health_port
        self.client_address = None
        self.transport = None
        self.targets = {}
        self.tasks = set()
        self.closed = False

    def connection_made(self, transport):
        """Store the local UDP relay transport.

        Args:
            transport: Asynchronous datagram transport.
        """
        self.transport = transport

    def datagram_received(self, data, address):
        """Validate and schedule a SOCKS UDP request.

        Args:
            data: SOCKS UDP datagram.
            address: Sender socket address.
        """
        if self.closed or address[0] != self.client_ip or (self.client_address and address != self.client_address):
            return
        try:
            host, port, payload = decode_datagram(data)
        except (ValueError, UnicodeError):
            return
        self.client_address = address
        if len(self.tasks) >= MAX_UDP_TASKS:
            LOGGER.warning("UDP association task limit reached")
            return
        task = asyncio.create_task(self.forward(host, port, payload))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def create_target(self, host, port):
        """Open one connected destination socket.

        Args:
            host: Requested destination host.
            port: Requested destination port.
        """
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.create_datagram_endpoint(
            lambda: RemoteDatagram(self, host, port), remote_addr=(host, port)
        )
        return transport, protocol

    async def forward(self, host, port, payload):
        """Forward a UDP payload, sharing destination creation across packets.

        Args:
            host: Requested destination host.
            port: Requested destination port.
            payload: UDP payload.
        """
        key = (host, port)
        task = self.targets.get(key)
        if task is None:
            if len(self.targets) >= MAX_UDP_TARGETS:
                LOGGER.warning("UDP destination limit reached")
                return
            task = asyncio.create_task(self.create_target(host, port))
            self.targets[key] = task
        try:
            transport, protocol = await asyncio.shield(task)
            if self.closed:
                return
            protocol.last_used = time.monotonic()
            transport.sendto(payload)
            if not health_destination(host, port, self.health_port):
                self.counters.add(destination_label(host), 0, len(payload))
        except (OSError, ValueError):
            if self.targets.get(key) is task:
                self.targets.pop(key, None)
            LOGGER.debug("UDP destination unavailable", exc_info=True)

    async def reap(self):
        """Close destination sockets that have been idle for too long."""
        while not self.closed:
            await asyncio.sleep(UDP_IDLE_SECONDS)
            for key, task in list(self.targets.items()):
                if task.done() and not task.cancelled() and task.exception() is None:
                    transport, protocol = task.result()
                    if time.monotonic() - protocol.last_used > UDP_IDLE_SECONDS:
                        transport.close()
                        self.targets.pop(key, None)

    async def close(self):
        """Cancel pending work and release all association sockets."""
        self.closed = True
        if self.transport:
            self.transport.close()
        tasks = list(self.tasks) + list(self.targets.values())
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for task in self.targets.values():
            if task.done() and not task.cancelled() and task.exception() is None:
                task.result()[0].close()
        self.targets.clear()


class SocksServer:
    """Accept authenticated Xray's loopback SOCKS connections."""

    def __init__(self, counters, health_port=None):
        """Initialize the forwarding server.

        Args:
            counters: Shared traffic accumulator.
            health_port: Reserved local health port, or None.
        """
        self.counters = counters
        self.health_port = health_port
        self.connections = 0
        self.tasks = set()

    async def handle(self, reader, writer):
        """Handle one bounded SOCKS5 connection.

        Args:
            reader: Client stream reader.
            writer: Client stream writer.
        """
        if self.connections >= MAX_CONNECTIONS:
            writer.close()
            await writer.wait_closed()
            return
        self.connections += 1
        task = asyncio.current_task()
        self.tasks.add(task)
        try:
            await self.negotiate(reader, writer)
        except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError, UnicodeError, ValueError):
            LOGGER.debug("SOCKS connection ended", exc_info=True)
        finally:
            writer.close()
            with contextlib.suppress(OSError, asyncio.CancelledError):
                await writer.wait_closed()
            self.connections -= 1
            self.tasks.discard(task)

    async def negotiate(self, reader, writer):
        """Negotiate a SOCKS command before starting its data path.

        Args:
            reader: Client stream reader.
            writer: Client stream writer.
        """
        header = await asyncio.wait_for(reader.readexactly(2), HANDSHAKE_SECONDS)
        version, count = header
        methods = await asyncio.wait_for(reader.readexactly(count), HANDSHAKE_SECONDS)
        if version != 5 or 0 not in methods:
            writer.write(b"\x05\xff")
            await writer.drain()
            return
        writer.write(b"\x05\x00")
        await writer.drain()
        version, command, reserved, atyp = await asyncio.wait_for(reader.readexactly(4), HANDSHAKE_SECONDS)
        if version != 5 or reserved:
            raise ValueError("Invalid SOCKS request")
        host, port = await asyncio.wait_for(read_address(reader, atyp), HANDSHAKE_SECONDS)
        if command == 1:
            await self.connect(reader, writer, host, port)
        elif command == 3:
            await self.udp_associate(reader, writer)
        else:
            writer.write(b"\x05\x07\x00\x01\0\0\0\0\0\0")
            await writer.drain()

    async def connect(self, reader, writer, host, port):
        """Relay a TCP stream while counting successfully forwarded data.

        Args:
            reader: Client stream reader.
            writer: Client stream writer.
            host: Requested destination.
            port: Requested destination port.
        """
        try:
            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(host, port, happy_eyeballs_delay=0.25), HANDSHAKE_SECONDS
            )
        except (OSError, asyncio.TimeoutError):
            writer.write(b"\x05\x05\x00\x01\0\0\0\0\0\0")
            await writer.drain()
            return
        domain = destination_label(host)
        excluded = health_destination(host, port, self.health_port)

        async def pump(source, target, direction):
            """Forward one direction and propagate half-close.

            Args:
                source: Input stream reader.
                target: Output stream writer.
                direction: Upload or download counter index.
            """
            try:
                while True:
                    data = await source.read(BUFFER_SIZE)
                    if not data:
                        if target.can_write_eof():
                            target.write_eof()
                            await target.drain()
                        return True
                    target.write(data)
                    await target.drain()
                    if not excluded:
                        self.counters.add(domain, direction, len(data))
            except (OSError, ConnectionError):
                return False

        tasks = []
        try:
            writer.write(b"\x05\x00\x00\x01\x7f\0\0\x01\0\0")
            await writer.drain()
            tasks = [asyncio.create_task(pump(reader, remote_writer, 0)), asyncio.create_task(pump(remote_reader, writer, 1))]
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            if any(not task.result() for task in done):
                for task in pending:
                    task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            remote_writer.close()
            with contextlib.suppress(OSError, asyncio.CancelledError):
                await remote_writer.wait_closed()

    async def udp_associate(self, reader, writer):
        """Keep a SOCKS UDP relay alive while its control stream is open.

        Args:
            reader: Client control stream reader.
            writer: Client control stream writer.
        """
        peer = writer.get_extra_info("peername")
        loop = asyncio.get_running_loop()
        transport, association = await loop.create_datagram_endpoint(
            lambda: UDPAssociation(peer[0], self.counters, self.health_port),
            local_addr=("127.0.0.1", 0),
        )
        reaper = asyncio.create_task(association.reap())
        try:
            port = transport.get_extra_info("sockname")[1]
            writer.write(b"\x05\x00\x00\x01\x7f\0\0\x01" + struct.pack("!H", port))
            await writer.drain()
            while await reader.read(4096):
                pass
        finally:
            reaper.cancel()
            await asyncio.gather(reaper, return_exceptions=True)
            await association.close()


async def serve(database, port, source, health_port):
    """Run the loopback-only asynchronous collector until stopped.

    Args:
        database: Existing SQLite database path.
        port: Loopback SOCKS port.
        source: Original or isolated preview node.
        health_port: Reserved health endpoint port, or None.
    """
    counters = Counters(database, source)
    counters.thread.start()
    handler = SocksServer(counters, health_port)
    server = await asyncio.start_server(handler.handle, "127.0.0.1", port, backlog=256)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    try:
        await stop.wait()
    finally:
        server.close()
        for task in list(handler.tasks):
            task.cancel()
        await asyncio.gather(*list(handler.tasks), return_exceptions=True)
        await server.wait_closed()
        counters.stop_event.set()
        await asyncio.to_thread(counters.thread.join, 15)


def main():
    """Start the asynchronous loopback collector."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--source", choices=(SOURCE_PREVIEW, SOURCE_ORIGINAL), default=SOURCE_ORIGINAL)
    parser.add_argument("--health-port", type=int)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    asyncio.run(serve(args.database, args.port, args.source, args.health_port))


if __name__ == "__main__":
    main()
