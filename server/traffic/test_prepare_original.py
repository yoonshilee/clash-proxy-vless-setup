"""Check that production shadow configuration never mutates the input."""

import copy
import unittest
from unittest.mock import patch

from prepare_original import COLLECTOR_PORT, HEALTH_V4_PORT, HEALTH_V6_PORT, MONITORED_PORT, build_configs


class PrepareOriginalTests(unittest.TestCase):
    """Validate shadow configuration and existing-node preservation."""

    def setUp(self):
        """Create a synthetic configuration without real credentials."""
        self.original = {
            "inbounds": [{"listen": "0.0.0.0", "port": 443, "protocol": "vless", "settings": {"clients": [{"id": "synthetic-client", "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"security": "reality", "realitySettings": {"privateKey": "synthetic-key", "shortIds": ["synthetic"], "serverNames": ["example.com"], "target": "example.com:443"}}}],
            "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}],
        }

    @patch("prepare_original.subprocess.check_output", return_value="Password (PublicKey): synthetic-public\n")
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
