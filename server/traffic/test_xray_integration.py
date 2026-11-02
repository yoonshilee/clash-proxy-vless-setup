"""Exercise an isolated REALITY chain without changing the existing proxy."""

import json
import os
from pathlib import Path
import re
import secrets
import socket
import socketserver
import sqlite3
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

from collector import decode_datagram, read_exact
from test_collector import negotiate

XRAY = os.environ.get("XRAY_TEST_BINARY")


def free_port():
    """Return an available loopback TCP port."""
    with socket.socket() as conn:
        conn.bind(("127.0.0.1", 0))
        return conn.getsockname()[1]


class Echo(socketserver.BaseRequestHandler):
    """Echo test payloads over a persistent TCP connection."""

    def handle(self):
        """Return payloads until the client closes the connection."""
        try:
            while data := self.request.recv(65536):
                self.request.sendall(data)
        except OSError:
            pass


class EchoServer(socketserver.ThreadingTCPServer):
    """Serve test connections without blocking cleanup."""

    allow_reuse_address = True
    daemon_threads = True


class Decoy(socketserver.BaseRequestHandler):
    """Offer a local TLS 1.3 handshake to the isolated REALITY listener."""

    def handle(self):
        """Accept one local TLS handshake without accessing the network."""
        try:
            with self.server.context.wrap_socket(self.request, server_side=True) as connection:
                connection.settimeout(5)
                connection.recv(1)
        except (OSError, ssl.SSLError):
            pass


@unittest.skipUnless(XRAY and Path(XRAY).is_file(), "Set XRAY_TEST_BINARY to run the Xray integration test")
class XrayIntegrationTests(unittest.TestCase):
    """Test REALITY forwarding, aggregation, and isolated failure."""

    def test_isolated_reality_and_failure(self):
        """Count traffic through REALITY and preserve an independent direct proxy."""
        root = Path(__file__).resolve().parent
        processes = []
        with tempfile.TemporaryDirectory() as directory, EchoServer(("127.0.0.1", 0), Echo) as target, EchoServer(("127.0.0.1", 0), Decoy) as decoy:
            thread = threading.Thread(target=target.serve_forever, daemon=True)
            thread.start()
            cert, key = Path(directory) / "cert.pem", Path(directory) / "key.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=www.cloudflare.com"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            decoy.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            decoy.context.minimum_version = ssl.TLSVersion.TLSv1_3
            decoy.context.set_alpn_protocols(["h2", "http/1.1"])
            decoy.context.load_cert_chain(cert, key)
            decoy_thread = threading.Thread(target=decoy.serve_forever, daemon=True)
            decoy_thread.start()
            env = dict(os.environ, TRAFFIC_DATA_DIR=directory, TRAFFIC_SECRET_KEY="integration-test-key")
            subprocess.run([sys.executable, str(root / "manage.py"), "migrate", "--noinput"], cwd=root, env=env, check=True, stdout=subprocess.DEVNULL)
            database = Path(directory) / "traffic.sqlite3"
            collector_port, server_port, client_port, direct_port = [free_port() for _ in range(4)]

            def start(command):
                """Launch one isolated process.

                Args:
                    command: Executable and arguments.
                """
                log = (Path(directory) / "process.log").open("ab")
                process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                log.close()
                processes.append(process)
                time.sleep(.4)
                self.assertIsNone(process.poll(), f"Failed to start {command[0]}")
                return process

            def launch_xray(name, config):
                """Write and launch a private temporary Xray configuration.

                Args:
                    name: Temporary config name.
                    config: Xray configuration object.
                """
                path = Path(directory) / name
                path.write_text(json.dumps(config))
                path.chmod(0o600)
                return start([XRAY, "run", "-c", str(path)])

            def transfer(port):
                """Send one payload through a local SOCKS listener.

                Args:
                    port: SOCKS listener port.
                """
                conn, _ = negotiate(port, 1, "localhost", target.server_address[1])
                with conn:
                    conn.sendall(b"x" * 1024)
                    return read_exact(conn, 1024)

            try:
                collector_name = "collector_async.py" if os.environ.get("XRAY_TEST_ASYNC") == "1" else "collector.py"
                collector = start([sys.executable, str(root / collector_name), "--database", str(database), "--port", str(collector_port)])
                keys = subprocess.check_output([XRAY, "x25519"], text=True)
                private = re.search(r"^PrivateKey:\s*(\S+)", keys, re.M).group(1)
                public = re.search(r"^Password \(PublicKey\):\s*(\S+)", keys, re.M).group(1)
                identity, short_id = str(uuid.uuid4()), secrets.token_hex(8)
                server = {"log": {"loglevel": "info"}, "inbounds": [{"listen": "127.0.0.1", "port": server_port, "protocol": "vless", "settings": {"clients": [{"id": identity, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"target": f"127.0.0.1:{decoy.server_address[1]}", "serverNames": ["www.cloudflare.com"], "privateKey": private, "shortIds": [short_id]}}}], "outbounds": [{"protocol": "socks", "settings": {"address": "127.0.0.1", "port": collector_port}}]}
                client = {"log": {"loglevel": "error"}, "inbounds": [{"listen": "127.0.0.1", "port": client_port, "protocol": "socks", "settings": {"udp": True}}], "outbounds": [{"protocol": "vless", "settings": {"address": "127.0.0.1", "port": server_port, "id": identity, "encryption": "none", "flow": "xtls-rprx-vision"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"fingerprint": "chrome", "serverName": "www.cloudflare.com", "password": public, "shortId": short_id}}}]}
                direct = {"log": {"loglevel": "error"}, "inbounds": [{"listen": "127.0.0.1", "port": direct_port, "protocol": "socks"}], "outbounds": [{"protocol": "freedom"}]}
                launch_xray("server.json", server)
                launch_xray("client.json", client)
                launch_xray("direct.json", direct)
                try:
                    self.assertEqual(transfer(client_port), b"x" * 1024)
                except (OSError, EOFError):
                    self.fail((Path(directory) / "process.log").read_text())
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp_target:
                    udp_target.bind(("127.0.0.1", 0))
                    udp_target.settimeout(5)

                    def echo_udp():
                        """Echo one UDP packet from the local target."""
                        payload, address = udp_target.recvfrom(1024)
                        udp_target.sendto(payload, address)

                    udp_thread = threading.Thread(target=echo_udp, daemon=True)
                    udp_thread.start()
                    control, udp_port = negotiate(client_port, 3, "0.0.0.0", 0)
                    with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client_udp:
                        client_udp.settimeout(5)
                        payload = b"integration-udp-payload"
                        packet = b"\0\0\0\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", udp_target.getsockname()[1]) + payload
                        client_udp.sendto(packet, ("127.0.0.1", udp_port))
                        response, _ = client_udp.recvfrom(1024)
                        self.assertEqual(decode_datagram(response)[2], payload)
                    udp_thread.join(timeout=5)
                time.sleep(1.5)
                with sqlite3.connect(database) as db:
                    self.assertEqual(db.execute("SELECT upload, download FROM dashboard_trafficminute WHERE domain='localhost'").fetchone(), (1024, 1024))
                    self.assertEqual(db.execute("SELECT upload, download FROM dashboard_trafficminute WHERE domain='Unknown'").fetchone(), (len(payload), len(payload)))
                connections = []
                try:
                    for _ in range(int(os.environ.get("XRAY_STRESS_CONNECTIONS", "0"))):
                        conn, _ = negotiate(client_port, 1, "localhost", target.server_address[1])
                        conn.sendall(b"x" * 1024)
                        self.assertEqual(read_exact(conn, 1024), b"x" * 1024)
                        connections.append(conn)
                    for conn in connections:
                        conn.sendall(b"y")
                    for conn in connections:
                        self.assertEqual(read_exact(conn, 1), b"y")
                finally:
                    for conn in connections:
                        conn.close()
                collector.terminate()
                collector.wait(timeout=5)
                self.assertEqual(transfer(direct_port), b"x" * 1024)
                with self.assertRaises((AssertionError, EOFError, OSError)):
                    transfer(client_port)
            finally:
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                target.shutdown()
                thread.join(timeout=5)
                decoy.shutdown()
                decoy_thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
