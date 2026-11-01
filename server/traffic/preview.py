"""Run an isolated, loopback-only preview without changing existing services."""

import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent
DATA_DIR = Path(os.environ["TRAFFIC_DATA_DIR"]).resolve()
WEB_PORT = int(os.environ.get("TRAFFIC_PREVIEW_WEB_PORT", "32850"))
COLLECTOR_PORT = int(os.environ.get("TRAFFIC_PREVIEW_COLLECTOR_PORT", "32851"))
REALITY_PORT = int(os.environ.get("TRAFFIC_PREVIEW_REALITY_PORT", "32852"))
SOCKS_PORT = int(os.environ.get("TRAFFIC_PREVIEW_SOCKS_PORT", "32853"))
REALITY_HOST = "www.cloudflare.com"
REALITY_TARGET = os.environ.get("TRAFFIC_REALITY_TARGET", f"{REALITY_HOST}:443")
XRAY = os.environ.get("TRAFFIC_XRAY", "/usr/local/bin/xray")


def private_file(path, contents):
    """Write a private file without modifying an existing one.

    Args:
        path: Destination path.
        contents: Text to store.
    """
    if not path.exists():
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(contents)


def reality_configs():
    """Create private loopback-only Xray client and server configurations."""
    server_path = DATA_DIR / "server.json"
    client_path = DATA_DIR / "client.json"
    if server_path.exists() and client_path.exists():
        return
    if server_path.exists() or client_path.exists():
        raise RuntimeError("Incomplete preview Xray configuration")
    keys = subprocess.check_output([XRAY, "x25519"], text=True)
    private = re.search(r"^PrivateKey:\s*(\S+)", keys, re.M).group(1)
    public = re.search(r"^Password \(PublicKey\):\s*(\S+)", keys, re.M).group(1)
    identity, short_id = str(uuid.uuid4()), secrets.token_hex(8)
    server = {"log": {"loglevel": "warning", "access": "none"}, "inbounds": [{"listen": "127.0.0.1", "port": REALITY_PORT, "protocol": "vless", "settings": {"clients": [{"id": identity, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"target": REALITY_TARGET, "serverNames": [REALITY_HOST], "privateKey": private, "shortIds": [short_id]}}}], "outbounds": [{"protocol": "socks", "settings": {"address": "127.0.0.1", "port": COLLECTOR_PORT}}]}
    client = {"log": {"loglevel": "warning", "access": "none"}, "inbounds": [{"listen": "127.0.0.1", "port": SOCKS_PORT, "protocol": "socks", "settings": {"udp": True}}], "outbounds": [{"protocol": "vless", "settings": {"address": "127.0.0.1", "port": REALITY_PORT, "id": identity, "encryption": "none", "flow": "xtls-rprx-vision"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"fingerprint": "chrome", "serverName": REALITY_HOST, "password": public, "shortId": short_id}}}]}
    private_file(server_path, json.dumps(server))
    private_file(client_path, json.dumps(client))


def setup():
    """Initialize private preview credentials, schema, and independent node."""
    os.umask(0o077)
    DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    secret_path = DATA_DIR / "secret"
    private_file(secret_path, secrets.token_urlsafe(48))
    os.environ["TRAFFIC_SECRET_KEY"] = secret_path.read_text().strip()
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "traffic.settings")
    subprocess.run([sys.executable, str(ROOT / "manage.py"), "migrate", "--noinput"], cwd=ROOT, check=True)
    import django

    django.setup()
    from django.contrib.auth import get_user_model

    user_model = get_user_model()
    credential_path = DATA_DIR / "preview-login.txt"
    if not user_model.objects.filter(username="preview").exists():
        private_file(credential_path, f"username: preview\npassword: {secrets.token_urlsafe(24)}\n")
        password_line = next(line for line in credential_path.read_text().splitlines() if line.startswith("password: "))
        user_model.objects.create_user(username="preview", password=password_line.removeprefix("password: "))
    elif not credential_path.exists():
        raise RuntimeError("Preview credentials are missing")
    reality_configs()


def main():
    """Supervise independent loopback-only preview processes."""
    setup()
    commands = [
        [sys.executable, str(ROOT / "collector.py"), "--database", str(DATA_DIR / "traffic.sqlite3"), "--port", str(COLLECTOR_PORT)],
        [XRAY, "run", "-c", str(DATA_DIR / "server.json")],
        [XRAY, "run", "-c", str(DATA_DIR / "client.json")],
        [sys.executable, str(ROOT / "manage.py"), "run_traffic_scheduler"],
        [sys.executable, "-m", "gunicorn", "traffic.wsgi:application", "--bind", f"127.0.0.1:{WEB_PORT}", "--workers", "1", "--threads", "2", "--log-level", "warning"],
    ]
    processes = []
    stopping = False

    def stop(_signum, _frame):
        """Request an orderly shutdown of the preview.

        Args:
            _signum: Signal number.
            _frame: Interrupted stack frame.
        """
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        for command in commands:
            processes.append(subprocess.Popen(command, cwd=ROOT))
        while not stopping:
            for process in processes:
                if process.poll() is not None:
                    raise RuntimeError("A preview process exited unexpectedly")
            time.sleep(1)
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
        for process in reversed(processes):
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
