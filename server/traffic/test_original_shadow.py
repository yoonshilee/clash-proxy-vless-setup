"""Validate the original-node shadow and dual-stack health path locally."""

import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

from test_xray_integration import Decoy, EchoServer, XRAY, free_port


@unittest.skipUnless(XRAY and Path(XRAY).is_file(), "Set XRAY_TEST_BINARY to run the original-node shadow test")
class OriginalShadowTests(unittest.TestCase):
    """Exercise the shadow without enabling any network redirect."""

    def test_shadow_health_without_routing_changes(self):
        """Validate cloned REALITY settings, byte persistence, and both probes."""
        root = Path(__file__).resolve().parent
        processes = []
        with tempfile.TemporaryDirectory() as directory, EchoServer(("127.0.0.1", 0), Decoy) as decoy:
            state = Path(directory)
            cert, key = state / "cert.pem", state / "key.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=www.cloudflare.com"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            decoy.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            decoy.context.minimum_version = ssl.TLSVersion.TLSv1_3
            decoy.context.set_alpn_protocols(["h2", "http/1.1"])
            decoy.context.load_cert_chain(cert, key)
            threading.Thread(target=decoy.serve_forever, daemon=True).start()
            ports = set()
            while len(ports) < 5:
                ports.add(free_port())
            shadow_port, collector_port, health_v4, health_v6, health_target = ports
            env = dict(os.environ, TRAFFIC_DATA_DIR=directory, TRAFFIC_SECRET_KEY="shadow-test", TRAFFIC_XRAY=XRAY, TRAFFIC_ORIGINAL_SHADOW_PORT=str(shadow_port), TRAFFIC_ORIGINAL_COLLECTOR_PORT=str(collector_port), TRAFFIC_ORIGINAL_HEALTH_V4_PORT=str(health_v4), TRAFFIC_ORIGINAL_HEALTH_V6_PORT=str(health_v6), TRAFFIC_ORIGINAL_HEALTH_TARGET_PORT=str(health_target))
            subprocess.run([sys.executable, str(root / "manage.py"), "migrate", "--noinput"], cwd=root, env=env, stdout=subprocess.DEVNULL, check=True)
            keys = subprocess.check_output([XRAY, "x25519"], text=True)
            private = re.search(r"^PrivateKey:\s*(\S+)", keys, re.MULTILINE).group(1)
            original = {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "0.0.0.0", "port": 443, "protocol": "vless", "settings": {"clients": [{"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"target": f"127.0.0.1:{decoy.server_address[1]}", "serverNames": ["www.cloudflare.com"], "privateKey": private, "shortIds": [secrets.token_hex(8)]}}}], "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}]}
            source = state / "source.json"
            source.write_text(json.dumps(original))
            source.chmod(0o600)
            subprocess.run([sys.executable, str(root / "prepare_original.py"), "--source", str(source), "--state-dir", directory, "--uid", str(os.getuid()), "--gid", str(os.getgid())], cwd=root, env=env, stdout=subprocess.DEVNULL, check=True)
            status = state / "gate-status.json"
            with (state / "shadow.log").open("wb") as log:
                processes.append(subprocess.Popen([sys.executable, str(root / "original.py")], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT))
                processes.append(subprocess.Popen([sys.executable, str(root / "gate.py"), "--database", str(state / "traffic.sqlite3"), "--status", str(status)], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT))
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if any(process.poll() is not None for process in processes):
                        self.fail((state / "shadow.log").read_text())
                    if status.exists() and json.loads(status.read_text())["state"] == "healthy":
                        break
                    time.sleep(.2)
                else:
                    self.fail((state / "shadow.log").read_text())
                self.assertEqual(json.loads(status.read_text())["state"], "healthy")
                self.assertEqual(json.loads(source.read_text()), original)
            finally:
                for process in reversed(processes):
                    process.terminate()
                for process in reversed(processes):
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                decoy.shutdown()


if __name__ == "__main__":
    unittest.main()
