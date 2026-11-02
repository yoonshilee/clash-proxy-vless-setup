"""Exercise reporting, authentication, and settings without sending real email."""

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from unittest.mock import Mock, patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse

from prepare_original import HEALTH_TARGET_PORT

from .forms import ReportSettingsForm
from .constants import SOURCE_ORIGINAL, SOURCE_PREVIEW
from .journal import access_record, ingest
from .management.commands.run_traffic_scheduler import run_once
from .models import AccessMinute, JournalState, ReportSettings, TrafficMinute
from .reports import original_gate_status, original_rows, scheduled_period, send, summarize


class ReportTests(TestCase):
    """Check time ranges, email delivery, and authenticated access."""

    def setUp(self):
        """Create a user and two adjacent minute samples."""
        self.user = get_user_model().objects.create_user(username="admin", password="strong-test-password-123")
        self.start = datetime(2026, 1, 1, tzinfo=timezone.utc)
        TrafficMinute.objects.create(minute=self.start, domain="example.com", upload=4, download=8)
        TrafficMinute.objects.create(minute=self.start + timedelta(minutes=1), domain="Unknown", upload=2, download=1)

    def test_range_is_end_exclusive(self):
        """Exclude the sample exactly at the end of a range."""
        self.assertEqual(summarize(self.start, self.start + timedelta(minutes=1)), [{"domain": "example.com", "upload": 4, "download": 8}])

    def test_original_and_preview_bytes_are_separate(self):
        """Associate measured original-node bytes only with original-node data."""
        TrafficMinute.objects.create(minute=self.start, domain="example.com", source=SOURCE_ORIGINAL, upload=40, download=80)
        AccessMinute.objects.create(minute=self.start, domain="example.com", connections=3)
        end = self.start + timedelta(minutes=1)
        self.assertEqual(summarize(self.start, end, source=SOURCE_PREVIEW)[0]["upload"], 4)
        rows = original_rows(self.start, end)
        self.assertEqual(rows[0]["connections"], 3)
        self.assertEqual(rows[0]["traffic"]["upload"], 40)
        self.assertEqual(rows[0]["traffic"]["download"], 80)

    def test_stale_gate_status_does_not_claim_active_routing(self):
        """Show stale gate status as unavailable rather than active."""
        with tempfile.TemporaryDirectory() as directory:
            status = Path(directory) / "status.json"
            status.write_text(json.dumps({"state": "active", "updated": time.time() - 60}))
            with patch("dashboard.reports.GATE_STATUS_PATH", status):
                self.assertEqual(original_gate_status(), "not reporting")

    def test_dashboard_requires_login(self):
        """Redirect unauthenticated dashboard requests to login."""
        self.assertEqual(self.client.get(reverse("dashboard")).status_code, 302)

    def test_authenticated_dashboard_and_invalid_range(self):
        """Show aggregated data and reject a reversed time interval."""
        AccessMinute.objects.create(minute=self.start, domain="example.com", connections=1)
        self.client.force_login(self.user)
        response = self.client.get(reverse("dashboard"), {"start": "2026-01-01T00:00", "end": "2026-01-01T00:01"})
        self.assertContains(response, "example.com")
        self.assertContains(response, "Unavailable")
        self.assertNotContains(response, "Separate test node")
        self.assertNotContains(response, "Unknown</th>")
        response = self.client.get(reverse("dashboard"), {"start": "2026-01-01T00:01", "end": "2026-01-01T00:00"})
        self.assertContains(response, "Select a valid minute-aligned range.")

    def test_existing_password_is_not_cleared(self):
        """Keep an existing SMTP password when the password field is blank."""
        obj = ReportSettings.objects.create(password="private-value")
        form = ReportSettingsForm({"host": "smtp.example.com", "port": 587, "username": "", "password": "", "sender": "a@example.com", "recipient": "b@example.com", "security": "starttls", "frequency": "daily", "hour": 0, "minute": 0, "weekday": 0, "timezone": "UTC"}, instance=obj)
        self.assertTrue(form.is_valid(), form.errors)
        self.assertEqual(form.save().password, "private-value")

    def test_sorting_has_exact_values_and_distinguishes_missing_data(self):
        """Expose raw byte counts and keep missing values distinct from zero."""
        AccessMinute.objects.create(minute=self.start, domain="missing.example", connections=1)
        TrafficMinute.objects.create(minute=self.start, domain="large.example", source=SOURCE_ORIGINAL, upload=9007199254740993, download=0)
        self.client.force_login(self.user)
        response = self.client.get(reverse("dashboard"), {"start": "2026-01-01T00:00", "end": "2026-01-01T00:01"})
        self.assertContains(response, 'data-sort-value="9007199254740993"')
        self.assertContains(response, 'data-sort-value="0"')
        self.assertContains(response, 'data-sort-value="">Unavailable')
        self.assertContains(response, 'class="sort-button"', count=4)

    def test_email_uses_starttls_and_contains_totals(self):
        """Send the selected interval through encrypted SMTP."""
        TrafficMinute.objects.create(minute=self.start, domain="real.example", source=SOURCE_ORIGINAL, upload=6, download=9)
        AccessMinute.objects.create(minute=self.start, domain="Unknown", connections=1)
        settings = ReportSettings(host="smtp.example.com", port=587, username="a", password="secret", sender="a@example.com", recipient="b@example.com", security="starttls")
        with patch("dashboard.reports.smtplib.SMTP") as smtp:
            send(settings, self.start, self.start + timedelta(minutes=2))
        connection = smtp.return_value.__enter__.return_value
        self.assertTrue(connection.starttls.call_args.kwargs["context"].check_hostname)
        connection.login.assert_called_once_with("a", "secret")
        message = connection.send_message.call_args.args[0]
        self.assertIn("Upload: 6 bytes", message.get_content())
        self.assertIn("real.example", message.get_content())
        self.assertNotIn("example.com", message.get_content())
        self.assertIn("Unknown", message.get_content())

    def test_daily_schedule_uses_local_midnights(self):
        """Calculate report periods in the configured time zone."""
        settings = ReportSettings(frequency="daily", timezone="Asia/Shanghai", hour=9, minute=0)
        now = datetime(2026, 1, 2, 2, 0, tzinfo=timezone.utc)
        start, end = scheduled_period(settings, now)
        self.assertEqual(start, datetime(2025, 12, 31, 16, 0, tzinfo=timezone.utc))
        self.assertEqual(end, datetime(2026, 1, 1, 16, 0, tzinfo=timezone.utc))

    def test_scheduled_send_is_not_repeated_for_same_period(self):
        """Send once for the due interval, then wait for the next period."""
        ReportSettings.objects.create(pk=1, frequency="daily", timezone="UTC", hour=0, minute=0)
        now = self.start + timedelta(hours=2)
        with patch("dashboard.management.commands.run_traffic_scheduler.send") as send_mock:
            run_once(now)
            run_once(now + timedelta(minutes=1))
        send_mock.assert_called_once()

    def test_failed_scheduled_send_can_retry(self):
        """Keep the period unsent after an SMTP failure."""
        ReportSettings.objects.create(pk=1, frequency="daily", timezone="UTC", hour=0, minute=0)
        with patch("dashboard.management.commands.run_traffic_scheduler.send", side_effect=[OSError(), None]) as send_mock:
            with self.assertLogs("dashboard.management.commands.run_traffic_scheduler", level="WARNING"):
                run_once(self.start + timedelta(hours=1))
            self.assertIn("OSError", ReportSettings.objects.get(pk=1).last_error)
            run_once(self.start + timedelta(hours=1, minutes=1))
        self.assertEqual(send_mock.call_count, 2)
        self.assertEqual(ReportSettings.objects.get(pk=1).last_error, "")

    def test_starttls_delivery_to_local_server(self):
        """Deliver a report over a verified local TLS connection."""
        with tempfile.TemporaryDirectory() as directory, socket.socket() as listener:
            cert, key = Path(directory) / "cert.pem", Path(directory) / "key.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(cert, key)
            client_context = ssl.create_default_context(cafile=str(cert))
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(10)
            received = []

            def serve():
                """Serve the minimal SMTP dialogue used by the report sender."""
                conn, _ = listener.accept()
                conn.settimeout(10)
                conn.sendall(b"220 localhost ESMTP\r\n")
                plain = conn.makefile("rb")
                plain.readline()
                conn.sendall(b"250-localhost\r\n250 STARTTLS\r\n")
                plain.readline()
                conn.sendall(b"220 Ready for TLS\r\n")
                plain.close()
                with server_context.wrap_socket(conn, server_side=True) as secure:
                    stream = secure.makefile("rb")
                    while True:
                        line = stream.readline()
                        if line.upper().startswith(b"EHLO"):
                            secure.sendall(b"250 localhost\r\n")
                        elif line.upper().startswith((b"MAIL FROM", b"RCPT TO")):
                            secure.sendall(b"250 OK\r\n")
                        elif line.upper().startswith(b"DATA"):
                            secure.sendall(b"354 End with dot\r\n")
                            chunks = []
                            while True:
                                part = stream.readline()
                                if part in (b".\r\n", b""):
                                    break
                                chunks.append(part)
                            received.append(b"".join(chunks))
                            secure.sendall(b"250 Accepted\r\n")
                        elif line.upper().startswith(b"QUIT") or not line:
                            secure.sendall(b"221 Bye\r\n")
                            break
                    stream.close()

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            settings = ReportSettings(host="localhost", port=listener.getsockname()[1], sender="a@example.com", recipient="b@example.com", security="starttls")
            with patch("dashboard.reports.ssl.create_default_context", return_value=client_context):
                send(settings, self.start, self.start + timedelta(minutes=2))
            worker.join(timeout=5)
            self.assertEqual(len(received), 1)
            self.assertIn(b"example.com", received[0])


class JournalTests(TestCase):
    """Verify original-node access import and cursor handling."""

    def test_parse_domain_and_ip_without_client_address(self):
        """Record the destination, not the source, and classify IP-only targets."""
        base = {"__REALTIME_TIMESTAMP": "1767225600000000"}
        domain = dict(base, MESSAGE="from tcp:192.0.2.2:1234 accepted tcp:Example.COM:443 [direct]")
        ip = dict(base, MESSAGE="from tcp:192.0.2.2:1234 accepted udp:[2001:db8::1]:443 [direct]")
        self.assertEqual(access_record(domain)[1], "example.com")
        self.assertEqual(access_record(ip)[1], "Unknown")
        self.assertIsNone(access_record(dict(base, MESSAGE="unrelated log entry")))
        self.assertIsNone(access_record(dict(base, MESSAGE=f"accepted tcp:127.0.0.1:{HEALTH_TARGET_PORT} [direct]")))

    def test_cursor_is_committed_with_counts_and_reused(self):
        """Continue from the last committed cursor without recounting old records."""
        entries = [
            {"__CURSOR": "one", "__REALTIME_TIMESTAMP": "1767225600000000", "MESSAGE": "accepted tcp:example.com:443 [direct]"},
            {"__CURSOR": "two", "__REALTIME_TIMESTAMP": "1767225601000000", "MESSAGE": "accepted tcp:example.com:443 [direct]"},
            {"__CURSOR": "three", "__REALTIME_TIMESTAMP": "1767225602000000", "MESSAGE": "accepted tcp:example.com:443 [direct]"},
        ]
        first = Mock(stdout="\n".join(json.dumps(item) for item in entries[:2]))
        second = Mock(stdout=json.dumps(entries[2]))
        with patch("dashboard.journal.subprocess.run", side_effect=[first, second]) as run:
            self.assertTrue(ingest())
            self.assertTrue(ingest())
        self.assertIn("--after-cursor=two", run.call_args_list[1].args[0])
        self.assertEqual(AccessMinute.objects.get(domain="example.com").connections, 3)
        self.assertEqual(JournalState.objects.get(pk=1).cursor, "three")

    def test_failed_read_does_not_advance_cursor(self):
        """Keep the last cursor and counts after an invalid journal record."""
        JournalState.objects.create(pk=1, cursor="last-good")
        with patch("dashboard.journal.subprocess.run", return_value=Mock(stdout="not-json")):
            self.assertFalse(ingest())
        self.assertEqual(JournalState.objects.get(pk=1).cursor, "last-good")
        self.assertEqual(AccessMinute.objects.count(), 0)
