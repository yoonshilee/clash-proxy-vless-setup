"""Exercise the complete preview using loopback-only test services."""

import http.cookiejar
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
import urllib.request

from collector import read_exact
from test_collector import negotiate
from test_xray_integration import Decoy, Echo, EchoServer, XRAY, free_port


@unittest.skipUnless(XRAY and Path(XRAY).is_file(), "Set XRAY_TEST_BINARY to run the preview test")
class PreviewTests(unittest.TestCase):
    """Verify the isolated dashboard, node, and persisted traffic together."""

    def test_preview_end_to_end(self):
        """Log in and observe traffic sent through the separate test node."""
        root = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as directory, EchoServer(("127.0.0.1", 0), Decoy) as decoy, EchoServer(("127.0.0.1", 0), Echo) as target:
            cert, key = Path(directory) / "cert.pem", Path(directory) / "key.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=www.cloudflare.com"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            decoy.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            decoy.context.minimum_version = ssl.TLSVersion.TLSv1_3
            decoy.context.set_alpn_protocols(["h2", "http/1.1"])
            decoy.context.load_cert_chain(cert, key)
            for server in (decoy, target):
                threading.Thread(target=server.serve_forever, daemon=True).start()
            ports = set()
            while len(ports) < 4:
                ports.add(free_port())
            web_port, collector_port, reality_port, socks_port = ports
            env = dict(os.environ, TRAFFIC_DATA_DIR=directory, TRAFFIC_XRAY=XRAY, TRAFFIC_REALITY_TARGET=f"127.0.0.1:{decoy.server_address[1]}", TRAFFIC_PREVIEW_WEB_PORT=str(web_port), TRAFFIC_PREVIEW_COLLECTOR_PORT=str(collector_port), TRAFFIC_PREVIEW_REALITY_PORT=str(reality_port), TRAFFIC_PREVIEW_SOCKS_PORT=str(socks_port))
            with (Path(directory) / "preview.log").open("wb") as log:
                process = subprocess.Popen([sys.executable, "preview.py"], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), urllib.request.ProxyHandler({}))
                deadline = time.monotonic() + 20
                while True:
                    if process.poll() is not None:
                        self.fail((Path(directory) / "preview.log").read_text())
                    try:
                        login = opener.open(f"http://127.0.0.1:{web_port}/login/", timeout=1).read().decode()
                        break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise
                        time.sleep(.2)
                conn, _ = negotiate(socks_port, 1, "localhost", target.server_address[1])
                with conn:
                    conn.sendall(b"x" * 1024)
                    self.assertEqual(read_exact(conn, 1024), b"x" * 1024)
                time.sleep(2)
                password = (Path(directory) / "preview-login.txt").read_text().split("password: ", 1)[1].strip()
                token = re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"', login).group(1)
                data = urllib.parse.urlencode({"username": "preview", "password": password, "csrfmiddlewaretoken": token}).encode()
                login_url = f"http://127.0.0.1:{web_port}/login/"
                request = urllib.request.Request(login_url, data=data, headers={"Referer": login_url})
                page = opener.open(request, timeout=5).read().decode()
                self.assertIn("localhost", page)
                self.assertIn("1.0\xa0KB", page)
                self.assertIn("Collector: running", page)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                decoy.shutdown()
                target.shutdown()


if __name__ == "__main__":
    unittest.main()
