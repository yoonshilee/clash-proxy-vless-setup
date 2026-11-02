"""Prepare an isolated copy of the existing Xray inbound for validation."""

import argparse
import base64
import binascii
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ORIGINAL_PORT = int(os.environ.get("TRAFFIC_ORIGINAL_PORT", "443"))
MONITORED_PORT = int(os.environ.get("TRAFFIC_ORIGINAL_SHADOW_PORT", "32854"))
COLLECTOR_PORT = int(os.environ.get("TRAFFIC_ORIGINAL_COLLECTOR_PORT", "32855"))
HEALTH_V4_PORT = int(os.environ.get("TRAFFIC_ORIGINAL_HEALTH_V4_PORT", "32856"))
HEALTH_V6_PORT = int(os.environ.get("TRAFFIC_ORIGINAL_HEALTH_V6_PORT", "32857"))
HEALTH_TARGET_PORT = int(os.environ.get("TRAFFIC_ORIGINAL_HEALTH_TARGET_PORT", "32858"))
XRAY = os.environ.get("TRAFFIC_XRAY", "/usr/local/bin/xray")


def reality_public_key(private_key):
    """Derive the REALITY public key without exposing the private key in argv.

    Args:
        private_key: URL-safe base64 encoded X25519 private key.

    Returns:
        The matching URL-safe base64 encoded public key without padding.
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

    try:
        raw = base64.b64decode(private_key + "=" * (-len(private_key) % 4), altchars=b"-_", validate=True)
        key = X25519PrivateKey.from_private_bytes(raw)
    except (ValueError, TypeError, binascii.Error) as exc:
        raise ValueError("The REALITY private key is invalid") from exc
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.urlsafe_b64encode(public).rstrip(b"=").decode("ascii")


def build_configs(original):
    """Build isolated server and health-client configurations.

    Args:
        original: Existing Xray configuration object.

    Returns:
        The monitored server configuration and its local health client.
    """
    inbounds = original.get("inbounds", [])
    outbounds = original.get("outbounds", [])
    if len(inbounds) != 1 or inbounds[0].get("protocol") != "vless" or inbounds[0].get("port") != ORIGINAL_PORT:
        raise ValueError("The existing inbound does not match the supported VLESS listener")
    if not outbounds or outbounds[0].get("protocol") != "freedom":
        raise ValueError("The existing default outbound is not freedom")
    if set(outbounds[0]) - {"protocol", "tag"}:
        raise ValueError("The existing default outbound has unsupported custom settings")
    if original.get("log", {}).get("access") not in (None, ""):
        raise ValueError("The existing access-log destination is not supported")
    inbound = inbounds[0]
    if inbound.get("streamSettings", {}).get("security") != "reality":
        raise ValueError("The existing inbound does not use REALITY")
    reality = inbound["streamSettings"]["realitySettings"]
    clients = inbound.get("settings", {}).get("clients", [])
    if not clients or not reality.get("serverNames") or not reality.get("shortIds") or not reality.get("privateKey"):
        raise ValueError("The existing inbound is missing its health-client settings")
    if inbound.get("listen") not in (None, "0.0.0.0", "::"):
        raise ValueError("The existing listener address is not supported")

    public = reality_public_key(reality["privateKey"])
    server = copy.deepcopy(original)
    server["inbounds"][0]["port"] = MONITORED_PORT
    server["outbounds"][0] = {"protocol": "socks", "tag": outbounds[0].get("tag", "direct"), "settings": {"address": "127.0.0.1", "port": COLLECTOR_PORT}}

    local_inbounds = []
    local_outbounds = []
    rules = []
    for tag, address, port in (("health-v4", "127.0.0.1", HEALTH_V4_PORT), ("health-v6", "::1", HEALTH_V6_PORT)):
        local_inbounds.append({"tag": tag, "listen": "127.0.0.1", "port": port, "protocol": "socks"})
        local_outbounds.append({"tag": tag, "protocol": "vless", "settings": {"address": address, "port": MONITORED_PORT, "id": clients[0]["id"], "encryption": "none", "flow": clients[0].get("flow", "")}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"fingerprint": "chrome", "serverName": reality["serverNames"][0], "password": public, "shortId": reality["shortIds"][0]}}})
        rules.append({"type": "field", "inboundTag": [tag], "outboundTag": tag})
    client = {"log": {"loglevel": "warning", "access": "none"}, "inbounds": local_inbounds, "outbounds": local_outbounds, "routing": {"rules": rules}}
    return server, client


def prepare(source, state_dir, uid, gid):
    """Validate and write two new private configurations without overwriting.

    Args:
        source: Path to the existing Xray configuration.
        state_dir: Private dashboard state directory.
        uid: Owner UID for the new configurations.
        gid: Owner GID for the new configurations.
    """
    original = json.loads(source.read_text())
    server, client = build_configs(original)
    destinations = [state_dir / "original-server.json", state_dir / "original-client.json"]
    if any(path.exists() for path in destinations):
        raise FileExistsError("Original-node monitoring configuration already exists")
    created = []
    try:
        with tempfile.TemporaryDirectory(prefix="traffic-config-", dir=state_dir) as directory:
            for name, config, target in zip(("server.json", "client.json"), (server, client), destinations):
                staged = Path(directory) / name
                staged.write_text(json.dumps(config))
                staged.chmod(0o600)
                subprocess.run([XRAY, "run", "-test", "-config", str(staged)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                os.link(staged, target)
                created.append(target)
                os.chown(target, uid, gid)
    except BaseException:
        for path in created:
            path.unlink(missing_ok=True)
        raise


def verified_source_hash(source, state_dir):
    """Verify the shadow configurations still match the original node.

    Args:
        source: Path to the existing Xray configuration.
        state_dir: Private directory containing the prepared shadow files.

    Returns:
        SHA-256 of the verified original configuration bytes.
    """
    contents = source.read_bytes()
    server, client = build_configs(json.loads(contents))
    if json.loads((state_dir / "original-server.json").read_text()) != server or json.loads((state_dir / "original-client.json").read_text()) != client:
        raise ValueError("The original Xray configuration no longer matches the shadow")
    return hashlib.sha256(contents).hexdigest()


def main():
    """Prepare the original-node shadow instance as root."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    prepare(args.source, args.state_dir, args.uid, args.gid)
    print("Private shadow configurations prepared; the original Xray configuration is unchanged.")


if __name__ == "__main__":
    main()
