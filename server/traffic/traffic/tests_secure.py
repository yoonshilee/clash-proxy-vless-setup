"""Test HTTPS dashboard security with isolated Django test data."""

import io
from pathlib import Path
import stat
import tempfile

from django.contrib.auth import get_user_model
from django.core.management import call_command, CommandError
from django.test import Client, TestCase
from django.urls import reverse

from .security import client_ip


class SecureDashboardTests(TestCase):
    """Exercise login throttling and secure session settings."""

    def setUp(self):
        """Create an isolated administrator and trusted proxy headers."""
        self.user = get_user_model().objects.create_user(username="admin", password="local-test-password")
        self.client = Client(HTTP_HOST="traffic.example.com:9443", HTTP_X_FORWARDED_PROTO="https", HTTP_X_TRAFFIC_CLIENT_IP="192.0.2.10")

    def test_login_locks_out_one_client_without_locking_another(self):
        """Limit repeated failures by the proxy-provided client address."""
        for _ in range(5):
            self.client.post(reverse("login"), {"username": "admin", "password": "wrong"}, HTTP_X_FORWARDED_FOR="198.51.100.1")
        response = self.client.post(reverse("login"), {"username": "admin", "password": "local-test-password"}, HTTP_X_FORWARDED_FOR="198.51.100.2")
        self.assertEqual(response.status_code, 429)
        other = Client(HTTP_HOST="traffic.example.com:9443", HTTP_X_FORWARDED_PROTO="https", HTTP_X_TRAFFIC_CLIENT_IP="192.0.2.11")
        response = other.post(reverse("login"), {"username": "admin", "password": "local-test-password"})
        self.assertEqual(response.status_code, 302)
        self.assertTrue(response.cookies["vps_traffic_session"]["secure"])
        self.assertTrue(response.cookies["vps_traffic_session"]["httponly"])
        self.assertEqual(response.cookies["vps_traffic_session"]["samesite"], "Strict")

    def test_untrusted_hosts_and_unencrypted_requests_are_rejected(self):
        """Require the configured HTTPS host before serving dashboard data."""
        self.assertEqual(self.client.get("/", HTTP_HOST="other.example.com").status_code, 400)
        plain = Client(HTTP_HOST="traffic.example.com:9443")
        self.assertEqual(plain.get("/").status_code, 301)

    def test_invalid_client_header_uses_a_shared_fallback(self):
        """Treat missing or malformed proxy addresses as one client."""
        request = type("Request", (), {"META": {"HTTP_X_TRAFFIC_CLIENT_IP": "spoofed"}})()
        self.assertEqual(client_ip(request), "0.0.0.0")


class BootstrapAdminTests(TestCase):
    """Exercise private administrator initialization and repeat installs."""

    def test_credentials_are_private_and_existing_user_is_preserved(self):
        """Create a retrievable password without printing or rotating it."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "login.txt"
            output = io.StringIO()
            call_command("bootstrap_traffic_admin", credentials=path, stdout=output)
            password = path.read_text().splitlines()[1].removeprefix("password: ")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertTrue(get_user_model().objects.get(username="admin").check_password(password))
            self.assertNotIn(password, output.getvalue())
            call_command("bootstrap_traffic_admin", credentials=path, stdout=output)
            self.assertTrue(get_user_model().objects.get(username="admin").check_password(password))

    def test_refuses_insecure_or_stale_credentials(self):
        """Do not disclose weakly protected or obsolete credentials."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "login.txt"
            path.write_text("username: admin\npassword: synthetic\n")
            path.chmod(0o644)
            with self.assertRaises(CommandError):
                call_command("bootstrap_traffic_admin", credentials=path, stdout=io.StringIO())
            path.chmod(0o600)
            get_user_model().objects.create_user(username="admin", password="different-password")
            with self.assertRaises(CommandError):
                call_command("bootstrap_traffic_admin", credentials=path, stdout=io.StringIO())
