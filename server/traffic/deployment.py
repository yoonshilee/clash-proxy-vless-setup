"""Validate the server configuration before installing traffic monitoring."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import socket
import subprocess

import gate_setup
from prepare_original import build_configs

HTTPS_PORT = 9443
RESERVED_PORTS = (32854, 32855, 32856, 32857, 32858, HTTPS_PORT)
SUPPORTED_OUTBOUNDS = frozenset(("freedom", "blackhole"))
EXPECTED_CADDY_IMPORT = "import /etc/caddy/Caddyfile.d/*.caddyfile"


def dashboard_hostname(address):
    """Build a host-only dashboard name for a public IPv4 address.

    Args:
        address: The configured VPS public IPv4 address.

    Returns:
        A distinct sslip.io hostname for the dashboard.
    """
    ip = ipaddress.ip_address(address)
    if ip.version != 4 or not ip.is_global:
        raise ValueError("The dashboard requires a public IPv4 address")
    return f"traffic.{ip}.sslip.io"


def validate_original(config):
    """Reject Xray configurations whose forwarding path cannot be monitored.

    Args:
        config: Existing Xray configuration object.
    """
    outbounds = config.get("outbounds", [])
    if any(item.get("protocol") not in SUPPORTED_OUTBOUNDS for item in outbounds):
        raise ValueError("The existing Xray configuration has unsupported outbounds")
    if sum(item.get("protocol") == "freedom" for item in outbounds) != 1:
        raise ValueError("The existing Xray configuration requires exactly one direct outbound")
    build_configs(config)


def verify_dns(hostname, address):
    """Require the dashboard hostname to resolve to the configured VPS.

    Args:
        hostname: Public dashboard hostname.
        address: Expected public IPv4 address.
    """
    answers = {item[4][0] for item in socket.getaddrinfo(hostname, HTTPS_PORT, socket.AF_UNSPEC, socket.SOCK_STREAM)}
    if answers != {str(ipaddress.ip_address(address))}:
        raise ValueError("The dashboard hostname does not resolve only to the configured VPS")


def verify_ports():
    """Reject conflicts with the dashboard or collector listeners."""
    sockets = []
    try:
        for port in RESERVED_PORTS:
            for family, host in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
                listener = socket.socket(family, socket.SOCK_STREAM)
                sockets.append(listener)
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if family == socket.AF_INET6:
                    listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                listener.bind((host, port))
                listener.listen(1)
    finally:
        for listener in sockets:
            listener.close()


def preflight(source, address, caddyfile):
    """Verify the existing proxy and firewall without changing either.

    Args:
        source: Path to the current Xray JSON configuration.
        address: Configured VPS public IPv4 address.
        caddyfile: Path to the existing Caddy configuration.

    Returns:
        The dashboard hostname.
    """
    config = json.loads(source.read_text())
    validate_original(config)
    gate_setup.validate_policy(gate_setup.ruleset())
    if EXPECTED_CADDY_IMPORT not in caddyfile.read_text().splitlines():
        raise ValueError("The existing Caddy configuration does not import the expected site directory")
    hostname = dashboard_hostname(address)
    verify_dns(hostname, address)
    verify_ports()
    return hostname


def main():
    """Run read-only deployment checks and print only the dashboard hostname."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--public-ip", required=True)
    parser.add_argument("--caddyfile", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        print(preflight(args.source, args.public_ip, args.caddyfile))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise SystemExit(f"Traffic dashboard preflight failed: {type(exc).__name__}: {exc}") from None


if __name__ == "__main__":
    main()
