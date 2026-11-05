# Domain Traffic Dashboard

The dashboard reports the domains and application bytes observed for new connections through the existing Xray node. It stores minute-level data for 90 days and can send a selected time range or a daily or weekly report through one configured SMTP account. Times are UTC by default.

## License

This dashboard is covered by the repository's [noncommercial license](../../LICENSE). Commercial deployment requires prior, separate written authorization unless an independently applicable earlier license already permits that use. See the [licensing guide](../../docs/licensing.md) for the version boundary, third-party terms, and the limited XERJ indexing permission. A new dashboard installation includes a copy of the project license in its application directory.

## Requirements

Install the proxy and subscription first. The dashboard installer currently supports a Debian-family VPS with systemd, an active UFW firewall with IPv4 and IPv6 enabled, Python 3.11 or newer with `venv`, Caddy, and a public IPv4 address recorded in `server/config/setup.conf`. The existing Xray configuration and UFW rules must pass the installer's checks. The dashboard does not support firewalld. Ports 9443 and 32854–32858 must be available. DNS for the generated `traffic.<public IPv4>.sslip.io` hostname must resolve to the VPS, and Caddy must be able to obtain and renew a public certificate. Allow TCP ports 80 and 9443 through any provider firewall as well as UFW.

Run these commands on the VPS from the repository directory:

```sh
sudo bash server/traffic/install.sh --check
sudo bash server/traffic/install.sh --install
```

The check validates the server and downloads the required Python packages into a temporary directory. It does not change the proxy, firewall, Caddy configuration, or services. The install stops if it detects an existing preview or an unsupported configuration; it does not automatically migrate preview data. If installation fails, it attempts to disable the new services and remove its dashboard site and firewall opening. When traffic was already redirected, it leaves the collector running so those connections can finish. The new files are retained for inspection and the installer refuses to overwrite them on a retry; check the service and firewall state before further changes.

## Open and secure the dashboard

The installer prints the HTTPS address and the administrator username, `admin`. It creates a random initial password in `/etc/clash-traffic/admin-login.txt`, readable by root only. Retrieve it on the VPS:

```sh
sudo cat /etc/clash-traffic/admin-login.txt
```

Open the printed HTTPS URL on your own computer and sign in. Save the password in a password manager and remove the credentials file once it has been saved. Do not share the password, the file contents, or installer output that contains subscription credentials.

To set a new administrator password on the VPS, run:

```sh
sudo env DJANGO_SETTINGS_MODULE=traffic.secure_settings TRAFFIC_DATA_DIR=/var/lib/clash-traffic \
  TRAFFIC_PUBLIC_HOST="$(sudo sed -n 's/^TRAFFIC_PUBLIC_HOST=//p' /etc/clash-traffic/environment)" \
  /opt/clash-traffic/venv/bin/python /opt/clash-traffic/app/manage.py changepassword admin
sudo rm -f /etc/clash-traffic/admin-login.txt
```

The dashboard is served over HTTPS by Caddy through a private local socket. Its application account cannot read the Xray private configuration. Login failures are limited by client IP; after five failures, the address is temporarily blocked for 15 minutes. The application and collector share the traffic database. SMTP credentials are stored in that database and must be protected by restricting server access and backups.

## Access an existing preview

The preview runs only on the VPS loopback interface. To view an already installed preview, set `VPS_SSH_TARGET` to the SSH username and address you use for that VPS, and run this command on your own computer:

```sh
ssh -N -L 32850:127.0.0.1:32850 "$VPS_SSH_TARGET"
```

Keep the terminal open and visit <http://127.0.0.1:32850/> on the same computer. The preview username is `preview`. To read the initial password, connect to the VPS in another terminal and run:

```sh
sudo cat /var/lib/private/clash-traffic-preview/preview-login.txt
```

Closing the SSH tunnel does not stop the proxy. If the page is unavailable, check `sudo systemctl status clash-traffic-preview.service --no-pager` on the VPS. The preview does not have the public dashboard's separate application and collector accounts; migrating an existing preview requires a separate procedure.

## Effects on the existing proxy

Installation does not restart Xray or replace its configuration, and Caddy is reloaded to add the dashboard site. The installer opens TCP 9443 in UFW and installs a firewall gate: healthy new connections are sent to a separate collector using the existing node credentials. Connections already established on the original Xray listener continue there. If collection becomes unhealthy, the watchdog returns new connections to the original listener; connections already using the collector can be interrupted. The redirect expires within 12 seconds if the watchdog stops. Existing connections cannot be measured retroactively, and collection failures or abrupt termination can leave gaps.

The watchdog also falls back when the original Xray configuration or the verified firewall policy changes. Review the collector and watchdog status after changing either; a changed configuration is not automatically copied into the collector.

The collector counts successfully forwarded application bytes, excluding protocol overhead. IP-only destinations appear as `Unknown`; traffic on a connection is attributed to the destination supplied to the proxy. The values do not represent VPS billing totals. The original Xray journal supplies domain access counts without byte counts.

## Email and checks

Configure one recipient and SMTP credentials in the dashboard. STARTTLS and implicit TLS are supported. Scheduled reports are retried after a failure; a message accepted by the SMTP server before a process interruption can be sent twice.

Check the services on the VPS:

```sh
sudo systemctl status clash-traffic-web.service clash-traffic-capture.service clash-traffic-gate.service
sudo journalctl -u clash-traffic-capture.service -u clash-traffic-gate.service -n 100
```

The date-time picker is served locally. No external CDN is required.

## Local verification

In a Python 3.12 virtual environment, install `requirements.txt`. From this directory, run:

```sh
python -m unittest -v test_collector test_deployment test_gate test_prepare_original
TRAFFIC_DATA_DIR=/tmp/traffic-test TRAFFIC_SECRET_KEY=local-test-key python manage.py test dashboard
```

Set `XRAY_TEST_BINARY` to a local Xray binary when running `test_xray_integration`. Tests use temporary credentials and do not require access to a VPS.
