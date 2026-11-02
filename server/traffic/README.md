# Domain Traffic Preview

This preview reads access records from the existing Xray service and shows its destination domains and connection counts. It also runs a separate loopback-only Xray node, a SOCKS traffic collector, a dashboard, and an email scheduler. The existing Xray service and subscription remain separate from the test node.

The original Xray access log provides destination records but does not provide byte counts. The first journal read imports at most 1,000 entries from the previous 15 minutes; later reads continue from the saved journal cursor. The reader stores destination domains and connection counts, not client addresses.

When original-node collection is active, new connections pass through a separate Xray listener and collector using the existing node credentials. Existing connections continue on the original listener and cannot be measured retroactively. A health watchdog returns new connections to the original listener when collection is unhealthy; connections already using the collector can be interrupted if it fails. The redirect expires within 12 seconds if the watchdog stops. Measured bytes exclude protocol overhead, and periods when collection is inactive can be incomplete.

The separate test-node collector counts successfully forwarded application bytes by domain and UTC minute. IP-only destinations are shown as `Unknown`; protocol overhead is not included. Connections carrying requests for more than one domain are attributed to the destination supplied to the proxy. The totals are not a VPS billing measurement. Data is retained for 90 days. Traffic while a reader is stopped, journal entries are rotated away, or pending counters are lost during an abrupt termination can create gaps.

## Local verification

Create a Python 3.12 virtual environment, install `requirements.txt`, and set `XRAY_TEST_BINARY` to a local Xray 26.3.27 binary. From this directory, run:

```sh
python -m unittest -v test_collector test_xray_integration test_preview
TRAFFIC_DATA_DIR=/tmp/traffic-test TRAFFIC_SECRET_KEY=local-test-key python manage.py test dashboard
```

The tests create temporary configuration and credentials. They do not require access to the VPS.

## Isolated VPS preview

Run the preview only on a Linux VPS with systemd, an existing Xray binary at `/usr/local/bin/xray`, and Python 3.12. Install the Python requirements into a dedicated directory readable by the preview service; do not install them into the system Python environment. Copy this directory to a dedicated, root-owned application directory, then start the preview with `TRAFFIC_PREVIEW_PYTHONPATH` set to the dependency directory:

```sh
sudo TRAFFIC_PREVIEW_PYTHONPATH=/opt/clash-traffic-preview/deps bash /opt/clash-traffic-preview/app/start-preview.sh
sudo systemctl status clash-traffic-preview.service
```

The transient service uses a private systemd user with read access to the systemd journal, a 256 MiB memory limit, a 25% CPU quota, and separate persistent data in `/var/lib/clash-traffic-preview`. It binds only to loopback and does not open firewall ports. When the `clash-traffic-autostart.service` systemd unit is installed and enabled, it verifies the UFW policy and starts the dashboard and original-node collector after boot. If the firewall check fails, the collector is not activated and the original listener remains available.

Set `TRAFFIC_VPS_SSH_TARGET` to the SSH destination already used to access the VPS. Open an SSH tunnel from the personal computer using the same identity:

```sh
ssh -N -L 32850:127.0.0.1:32850 -L 32853:127.0.0.1:32853 "$TRAFFIC_VPS_SSH_TARGET"
```

Open `http://127.0.0.1:32850/`. The initial dashboard login is stored in the root-readable `/var/lib/clash-traffic-preview/preview-login.txt` on the VPS. Send a test request from a second terminal:

```sh
curl --socks5-hostname 127.0.0.1:32853 https://example.com/
```

The SSH tunnel forwards TCP only. The collector's UDP path is exercised by the local automated tests; UDP traffic from a personal computer is not forwarded by this preview tunnel. To stop the preview, run `sudo systemctl stop clash-traffic-preview.service`. This does not delete its data.

## Email

The dashboard accepts one recipient and STARTTLS or implicit TLS SMTP settings. The password is stored in the preview's private SQLite database. Set a daily or weekly schedule and its IANA time zone, or send a selected UTC time range from the overview. Reports contain original-node access counts and measured byte totals, or label byte totals unavailable when no measurements exist. Scheduled reports are retried after failures; an interruption after the SMTP server accepts a message but before the sent marker is saved can produce a duplicate.

The overview uses the bundled Flatpickr 4.6.13 date-time picker. Dates and times are entered in UTC, with one-minute precision; the library is served locally and does not require a third-party CDN.

The preview is not a public-facing deployment. Do not expose its HTTP or SOCKS listeners to the internet.
