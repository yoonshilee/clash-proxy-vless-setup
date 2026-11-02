"""Check read-only deployment validation with synthetic server settings."""

import socket
import unittest
from unittest.mock import patch

import deployment


class DeploymentChecks(unittest.TestCase):
    """Reject server settings that could bypass or misdirect monitoring."""

    def test_dashboard_hostname_requires_public_ipv4(self):
        """Use a distinct DNS name and reject local or IPv6 addresses."""
        self.assertEqual(deployment.dashboard_hostname("1.1.1.1"), "traffic.1.1.1.1.sslip.io")
        for address in ("127.0.0.1", "10.0.0.1", "::1"):
            with self.assertRaises(ValueError):
                deployment.dashboard_hostname(address)

    def test_reserved_ports_reject_existing_listener(self):
        """Reject an active listener while allowing the released port."""
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("0.0.0.0", 0))
            listener.listen()
            port = listener.getsockname()[1]
            with patch.object(deployment, "RESERVED_PORTS", (port,)):
                with self.assertRaises(OSError):
                    deployment.verify_ports()
        with patch.object(deployment, "RESERVED_PORTS", (port,)):
            deployment.verify_ports()

    @patch("deployment.build_configs")
    def test_refuse_outbounds_that_skip_the_collector(self, build):
        """Accept one direct outbound and reject other forwarding paths."""
        deployment.validate_original({"outbounds": [{"protocol": "freedom"}, {"protocol": "blackhole"}]})
        build.assert_called_once()
        for outbounds in ([{"protocol": "freedom"}, {"protocol": "socks"}], [{"protocol": "freedom"}, {"protocol": "freedom"}]):
            with self.assertRaises(ValueError):
                deployment.validate_original({"outbounds": outbounds})

    @patch("deployment.socket.getaddrinfo")
    def test_dns_must_resolve_only_to_the_configured_vps(self, lookup):
        """Refuse a hostname that points to any other IPv4 address."""
        lookup.return_value = [(None, None, None, None, ("1.1.1.1", 9443))]
        deployment.verify_dns("traffic.1.1.1.1.sslip.io", "1.1.1.1")
        lookup.return_value.append((None, None, None, None, ("8.8.8.8", 9443)))
        with self.assertRaises(ValueError):
            deployment.verify_dns("traffic.1.1.1.1.sslip.io", "1.1.1.1")
