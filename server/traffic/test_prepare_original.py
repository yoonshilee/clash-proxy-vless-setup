"""Check that production shadow configuration never mutates the input."""

import copy
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from prepare_original import COLLECTOR_PORT, HEALTH_V4_PORT, HEALTH_V6_PORT, MONITORED_PORT, build_configs, reality_public_key, verified_source_hash


class PrepareOriginalTests(unittest.TestCase):
    """Validate shadow configuration and existing-node preservation."""

    def setUp(self):
        """Create a synthetic configuration without real credentials."""
        self.original = {
            "inbounds": [{"listen": "0.0.0.0", "port": 443, "protocol": "vless", "settings": {"clients": [{"id": "synthetic-client", "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"security": "reality", "realitySettings": {"privateKey": "synthetic-key", "shortIds": ["synthetic"], "serverNames": ["example.com"], "target": "example.com:443"}}}],
            "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}],
        }

    @patch("prepare_original.reality_public_key", return_value="synthetic-public")
    def test_shadow_preserves_original_and_uses_local_collector(self, _derive):
        """Create an independent listener and dual-stack health client."""
        before = copy.deepcopy(self.original)
        server, client = build_configs(self.original)
        self.assertEqual(self.original, before)
        self.assertEqual(server["inbounds"][0]["port"], MONITORED_PORT)
        self.assertEqual(server["outbounds"][0]["settings"]["port"], COLLECTOR_PORT)
        self.assertEqual(server["outbounds"][1], self.original["outbounds"][1])
        self.assertEqual([item["port"] for item in client["inbounds"]], [HEALTH_V4_PORT, HEALTH_V6_PORT])
        self.assertEqual([item["settings"]["address"] for item in client["outbounds"]], ["127.0.0.1", "::1"])

    def test_reject_unexpected_inbound(self):
        """Stop rather than guessing how to copy another deployment shape."""
        self.original["inbounds"][0]["port"] = 444
        with self.assertRaises(ValueError):
            build_configs(self.original)

    @patch("prepare_original.reality_public_key", return_value="synthetic-public")
    def test_reject_changed_original_config(self, _derive):
        """Do not activate a shadow using stale original-node credentials."""
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            source = state / "source.json"
            source.write_text(json.dumps(self.original))
            server, client = build_configs(self.original)
            (state / "original-server.json").write_text(json.dumps(server))
            (state / "original-client.json").write_text(json.dumps(client))
            self.assertEqual(len(verified_source_hash(source, state)), 64)
            self.original["inbounds"][0]["settings"]["clients"][0]["id"] = "changed-client"
            source.write_text(json.dumps(self.original))
            with self.assertRaises(ValueError):
                verified_source_hash(source, state)

    def test_reject_invalid_reality_private_key(self):
        """Reject malformed private keys without spawning a subprocess."""
        with self.assertRaises(ValueError):
            reality_public_key("not-a-valid-key")

    @unittest.skipUnless(os.environ.get("XRAY_TEST_BINARY"), "Set XRAY_TEST_BINARY to compare Xray output")
    def test_public_key_matches_xray(self):
        """Derive the same public key as Xray using synthetic key material."""
        private = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode()
        output = subprocess.check_output([os.environ["XRAY_TEST_BINARY"], "x25519", "-i", private], text=True)
        expected = re.search(r"^Password \(PublicKey\):\s*(\S+)", output, re.MULTILINE).group(1)
        self.assertEqual(reality_public_key(private), expected)
