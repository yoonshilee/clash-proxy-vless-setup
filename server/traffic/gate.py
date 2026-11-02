"""Keep an optional original-node traffic gate healthy and fail open."""

import argparse
import asyncio
import contextlib
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import sqlite3
import struct
import tempfile
import time

from dashboard.constants import SOURCE_ORIGINAL
from prepare_original import HEALTH_TARGET_PORT, HEALTH_V4_PORT, HEALTH_V6_PORT, MONITORED_PORT, ORIGINAL_PORT

GATE_TABLE = "clash_traffic_original"
GATE_SET = "active_ports"
GATE_COMMENT = "clash-traffic-original-v1"
GATE_TTL_SECONDS = 12
GATE_PROTECT_DIRECT = os.environ.get("TRAFFIC_GATE_PROTECT_DIRECT") == "1"
HEALTH_INTERVAL_SECONDS = 2
HEALTH_TIMEOUT_SECONDS = 3
HEARTBEAT_SECONDS = 12
STATUS_PATH = Path("/run/clash-traffic-gate/status.json")
ORIGINAL_CONFIG = Path("/usr/local/etc/xray/config.json")


def compatible_gate_rule(rule):
    """Identify the iptables-compatible gate expression in a UFW chain.

    Args:
        rule: One decoded nftables rule.
    """
    expected_port = {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": MONITORED_PORT}}
    expression = rule.get("expr", [])
    return (rule.get("table") == "filter" and (rule.get("family"), rule.get("chain")) in (("ip", "ufw-user-input"), ("ip6", "ufw6-user-input"))
            and len(expression) == 5 and expression[0] == expected_port
            and expression[1] == {"xt": {"type": "match", "name": "conntrack"}}
            and expression[2] == {"xt": {"type": "match", "name": "comment"}}
            and "counter" in expression[3] and expression[4] == {"accept": None})


def compatible_gate_arguments(chain):
    """Return the exact iptables rule for an original-port redirect.

    Args:
        chain: UFW input chain.
    """
    return [chain, "-p", "tcp", "--dport", str(MONITORED_PORT), "-m", "conntrack", "--ctorigdstport", str(ORIGINAL_PORT), "-m", "comment", "--comment", GATE_COMMENT, "-j", "ACCEPT"]


async def run_command(command, data=None):
    """Run a bounded command without exposing its output to logs.

    Args:
        command: Executable and arguments.
        data: Optional UTF-8 input.

    Returns:
        Standard output on success.
    """
    process = await asyncio.create_subprocess_exec(*command, stdin=asyncio.subprocess.PIPE if data is not None else asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    try:
        stdout, _ = await asyncio.wait_for(process.communicate(data.encode() if data is not None else None), HEALTH_TIMEOUT_SECONDS)
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()
        raise
    if process.returncode:
        raise OSError("Command failed")
    return stdout.decode()


def firewall_fingerprint(document):
    """Hash existing firewall rules, excluding the monitoring gate.

    Args:
        document: Decoded nftables ruleset.
    """
    def scrub(value):
        """Remove volatile kernel handles and counter values.

        Args:
            value: Nested JSON value.
        """
        if isinstance(value, dict):
            return {key: scrub(item) for key, item in value.items() if key not in ("handle", "index", "packets", "bytes")}
        if isinstance(value, list):
            return [scrub(item) for item in value]
        return value

    policy = []
    for item in document.get("nftables", []):
        for kind in ("table", "chain", "rule", "set", "element"):
            obj = item.get(kind)
            if not isinstance(obj, dict):
                continue
            if obj.get("family") == "inet" and (obj.get("table") == GATE_TABLE or (kind == "table" and obj.get("name") == GATE_TABLE)):
                continue
            if kind == "rule" and obj.get("comment") == GATE_COMMENT and obj.get("table") == "filter" and (obj.get("family"), obj.get("chain")) in (("ip", "ufw-user-input"), ("ip6", "ufw6-user-input")):
                continue
            if kind == "rule" and GATE_PROTECT_DIRECT and compatible_gate_rule(obj):
                continue
            policy.append({kind: scrub(obj)})
    payload = json.dumps(policy, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def gate_structure_valid(document):
    """Require the expected NAT gate without accepting additional rules.

    Args:
        document: Decoded nftables ruleset.
    """
    objects = {kind: [] for kind in ("table", "set", "chain", "rule")}
    for item in document.get("nftables", []):
        for kind in objects:
            obj = item.get(kind)
            if isinstance(obj, dict) and obj.get("family") == "inet" and (obj.get("table") == GATE_TABLE or (kind == "table" and obj.get("name") == GATE_TABLE)):
                objects[kind].append(obj)
    expected_counts = {"table": 1, "set": 1, "chain": 2 if GATE_PROTECT_DIRECT else 1, "rule": 3 if GATE_PROTECT_DIRECT else 1}
    if any(len(items) != expected_counts[kind] for kind, items in objects.items()):
        return False
    table, gate_set = objects["table"][0], objects["set"][0]
    chains = {item.get("name"): item for item in objects["chain"]}
    chain = chains.get("prerouting", {})
    redirect_rules = [item for item in objects["rule"] if item.get("chain") == "prerouting"]
    if len(redirect_rules) != 1:
        return False
    rule = redirect_rules[0]
    if GATE_PROTECT_DIRECT:
        protection = chains.get("protect-input", {})
        protected_rules = [item.get("expr") for item in objects["rule"] if item.get("chain") == "protect-input"]
        loopback = [{"match": {"op": "==", "left": {"meta": {"key": "iifname"}}, "right": "lo"}}, {"accept": None}]
        destination = {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": MONITORED_PORT}}
        original = {"match": {"op": "!=", "left": {"ct": {"key": "proto-dst", "dir": "original"}}, "right": ORIGINAL_PORT}}
        if protection.get("type") != "filter" or protection.get("hook") != "input" or protection.get("prio") != -10 or protection.get("policy") != "accept" or protected_rules != [loopback, [destination, original, {"drop": None}]]:
            return False
    expected_match = {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": f"@{GATE_SET}"}}
    elements = gate_set.get("elem", [])
    if not isinstance(elements, list) or len(elements) > 1:
        return False
    for item in elements:
        element = item.get("elem", {}) if isinstance(item, dict) else {}
        if element.get("val") != ORIGINAL_PORT or not isinstance(element.get("expires"), (int, float)) or not 0 <= element["expires"] <= GATE_TTL_SECONDS:
            return False
    return (table.get("name") == GATE_TABLE and gate_set.get("name") == GATE_SET and gate_set.get("type") == "inet_service" and gate_set.get("flags") == ["timeout"] and gate_set.get("timeout") == GATE_TTL_SECONDS and chain.get("name") == "prerouting" and chain.get("type") == "nat" and chain.get("hook") == "prerouting" and chain.get("prio") == -100 and chain.get("policy") == "accept" and rule.get("chain") == "prerouting" and rule.get("expr") == [expected_match, {"redirect": {"port": MONITORED_PORT}}])


def chain_jumps(document):
    """Extract jump targets from one nftables JSON chain.

    Args:
        document: Decoded nftables JSON response.
    """
    return {expr["jump"]["target"] for item in document.get("nftables", []) if "rule" in item for expr in item["rule"].get("expr", []) if "jump" in expr}


def gate_rule_present(document):
    """Check that a chain contains the narrowly scoped gate rule.

    Args:
        document: Decoded nftables JSON response.
    """
    rules = [item["rule"] for item in document.get("nftables", []) if item.get("rule", {}).get("comment") == GATE_COMMENT]
    if len(rules) != 1:
        return False
    expression = rules[0].get("expr", [])
    expected_port = {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": MONITORED_PORT}
    expected_original = {"op": "==", "left": {"ct": {"key": "proto-dst", "dir": "original"}}, "right": ORIGINAL_PORT}
    matches = [item["match"] for item in expression if "match" in item]
    verdicts = [item for item in expression if "accept" in item]
    return len(matches) == 2 and expected_port in matches and expected_original in matches and len(verdicts) == 1 and all(set(item) <= {"match", "accept", "counter"} for item in expression)


async def firewall_ready(expected_fingerprint):
    """Check the original firewall policy and both UFW gate rules.

    Args:
        expected_fingerprint: Fingerprint captured before gate installation.
    """
    ruleset = json.loads(await run_command(["nft", "-j", "list", "ruleset"]))
    if firewall_fingerprint(ruleset) != expected_fingerprint or not gate_structure_valid(ruleset):
        return False

    def chain(family, name):
        """Select one filter chain from the same ruleset snapshot.

        Args:
            family: nftables address family.
            name: Chain name.
        """
        return {"nftables": [item for item in ruleset.get("nftables", []) if item.get("rule", {}).get("family") == family and item["rule"].get("table") == "filter" and item["rule"].get("chain") == name]}

    for family, prefix in (("ip", "ufw"), ("ip6", "ufw6")):
        root = chain(family, "INPUT")
        before = chain(family, f"{prefix}-before-input")
        user = chain(family, f"{prefix}-user-input")
        if f"{prefix}-before-input" not in chain_jumps(root) or f"{prefix}-user-input" not in chain_jumps(before):
            return False
        if GATE_PROTECT_DIRECT:
            candidates = [item["rule"] for item in user["nftables"] if compatible_gate_rule(item["rule"])]
            if len(candidates) != 1:
                return False
            command = "iptables" if family == "ip" else "ip6tables"
            try:
                await run_command([command, "-C", *compatible_gate_arguments(f"{prefix}-user-input")])
            except (OSError, asyncio.TimeoutError):
                return False
        elif not gate_rule_present(user):
            return False
    return True


def collector_healthy(database):
    """Check that original-node byte samples are still being persisted.

    Args:
        database: SQLite database path.
    """
    try:
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=1) as db:
            row = db.execute("SELECT heartbeat FROM dashboard_collectorstatus WHERE source = ?", (SOURCE_ORIGINAL,)).fetchone()
        if not row or not row[0]:
            return False
        heartbeat = datetime.fromisoformat(row[0]).replace(tzinfo=timezone.utc)
        age = (datetime.now(timezone.utc) - heartbeat).total_seconds()
        return 0 <= age < HEARTBEAT_SECONDS
    except (OSError, ValueError, sqlite3.Error):
        return False


async def open_probe(port):
    """Open a persistent SOCKS connection through the shadow node.

    Args:
        port: Local health-client SOCKS port.
    """
    reader, writer = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", port), HEALTH_TIMEOUT_SECONDS)
    try:
        writer.write(b"\x05\x01\x00")
        await writer.drain()
        if await asyncio.wait_for(reader.readexactly(2), HEALTH_TIMEOUT_SECONDS) != b"\x05\x00":
            raise OSError("SOCKS negotiation failed")
        writer.write(b"\x05\x01\x00\x01\x7f\0\0\x01" + struct.pack("!H", HEALTH_TARGET_PORT))
        await writer.drain()
        header = await asyncio.wait_for(reader.readexactly(4), HEALTH_TIMEOUT_SECONDS)
        if header[0] != 5 or header[1] != 0 or header[2] != 0:
            raise OSError("SOCKS connection failed")
        if header[3] == 1:
            length = 4
        elif header[3] == 4:
            length = 16
        elif header[3] == 3:
            length = (await asyncio.wait_for(reader.readexactly(1), HEALTH_TIMEOUT_SECONDS))[0]
        else:
            raise OSError("Invalid SOCKS address")
        await asyncio.wait_for(reader.readexactly(length + 2), HEALTH_TIMEOUT_SECONDS)
        return reader, writer
    except BaseException:
        writer.close()
        with contextlib.suppress(OSError):
            await writer.wait_closed()
        raise


async def ping(probe):
    """Verify one established end-to-end health stream.

    Args:
        probe: Pair of stream reader and writer.
    """
    reader, writer = probe
    payload = secrets.token_bytes(8)
    writer.write(payload)
    await asyncio.wait_for(writer.drain(), HEALTH_TIMEOUT_SECONDS)
    if await asyncio.wait_for(reader.readexactly(len(payload)), HEALTH_TIMEOUT_SECONDS) != payload:
        raise OSError("Health response did not match")


async def refresh_gate():
    """Atomically renew the short-lived original-port redirect."""
    commands = f"flush set inet {GATE_TABLE} {GATE_SET}\nadd element inet {GATE_TABLE} {GATE_SET} {{ {ORIGINAL_PORT} timeout {GATE_TTL_SECONDS}s }}\n"
    await run_command(["nft", "-f", "-"], commands)


async def clear_gate():
    """Stop redirecting new connections while retaining existing NAT hooks."""
    await run_command(["nft", "-f", "-"], f"flush set inet {GATE_TABLE} {GATE_SET}\n")


def write_status(path, state):
    """Publish a non-sensitive, atomic status file.

    Args:
        path: Status file path.
        state: Current gate state.
    """
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump({"state": state, "updated": time.time()}, stream)
    temporary.chmod(0o644)
    os.replace(temporary, path)


async def echo(reader, writer):
    """Echo private health probes without using the public network.

    Args:
        reader: Health stream reader.
        writer: Health stream writer.
    """
    try:
        while data := await reader.read(1024):
            writer.write(data)
            await writer.drain()
    except OSError:
        pass
    finally:
        writer.close()
        with contextlib.suppress(OSError):
            await writer.wait_closed()


async def watch(database, activate, status_path, firewall_hash=None, original_hash=None):
    """Monitor both shadow paths and maintain the optional redirect.

    Args:
        database: SQLite database path.
        activate: Whether to redirect new original-node connections.
        status_path: Status file path.
        firewall_hash: Expected original UFW policy fingerprint.
        original_hash: Fingerprint of the verified original Xray configuration.
    """
    server = await asyncio.start_server(echo, "127.0.0.1", HEALTH_TARGET_PORT)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    probes = []
    try:
        while not stop.is_set():
            state = "fallback" if activate else "shadow"
            try:
                if not collector_healthy(database):
                    raise OSError("Collector heartbeat stale")
                if activate and original_hash and hashlib.sha256(ORIGINAL_CONFIG.read_bytes()).hexdigest() != original_hash:
                    raise OSError("Original Xray configuration changed")
                if activate and not await firewall_ready(firewall_hash):
                    raise OSError("Firewall gate is unavailable")
                if not probes:
                    candidates = await asyncio.gather(open_probe(HEALTH_V4_PORT), open_probe(HEALTH_V6_PORT), return_exceptions=True)
                    if any(isinstance(candidate, BaseException) for candidate in candidates):
                        for candidate in candidates:
                            if not isinstance(candidate, BaseException):
                                candidate[1].close()
                        raise OSError("A health path is unavailable")
                    probes = list(candidates)
                await asyncio.gather(*(ping(probe) for probe in probes))
                if activate:
                    await refresh_gate()
                    state = "active"
                else:
                    state = "healthy"
            except (OSError, ValueError, sqlite3.Error, asyncio.TimeoutError, asyncio.IncompleteReadError):
                if activate:
                    with contextlib.suppress(OSError, asyncio.TimeoutError):
                        await clear_gate()
                for _, writer in probes:
                    writer.close()
                probes = []
            write_status(status_path, state)
            try:
                await asyncio.wait_for(stop.wait(), HEALTH_INTERVAL_SECONDS)
            except asyncio.TimeoutError:
                pass
    finally:
        if activate:
            with contextlib.suppress(OSError, asyncio.TimeoutError):
                await clear_gate()
        for _, writer in probes:
            writer.close()
        server.close()
        await server.wait_closed()
        write_status(status_path, "fallback")


def main():
    """Run the watchdog in non-routing shadow mode unless explicitly enabled."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--status", type=Path, default=STATUS_PATH)
    parser.add_argument("--activate", action="store_true")
    parser.add_argument("--firewall-hash")
    parser.add_argument("--original-hash")
    args = parser.parse_args()
    if args.activate and not re.fullmatch(r"[0-9a-f]{64}", args.firewall_hash or ""):
        parser.error("--activate requires the verified firewall fingerprint")
    if args.activate and not re.fullmatch(r"[0-9a-f]{64}", args.original_hash or ""):
        parser.error("--activate requires the verified Xray configuration fingerprint")
    asyncio.run(watch(args.database, args.activate, args.status, args.firewall_hash, args.original_hash))


if __name__ == "__main__":
    main()
