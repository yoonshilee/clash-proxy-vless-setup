"""Test the fail-open gate without changing the host firewall."""

import asyncio
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import socket
import sqlite3
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import gate
import gate_setup
from collector_async import SocksServer
from test_collector import TestCounters


def rule_document():
    """Return a synthetic, narrowly scoped UFW gate rule."""
    return {"nftables": [{"rule": {"comment": gate.GATE_COMMENT, "expr": [
        {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": gate.MONITORED_PORT}},
        {"match": {"op": "==", "left": {"ct": {"key": "proto-dst", "dir": "original"}}, "right": gate.ORIGINAL_PORT}},
        {"accept": None},
    ]}}]}


def ufw_document():
    """Return a synthetic dual-stack UFW policy allowing the original port."""
    items = []
    for family, prefix in (("ip", "ufw"), ("ip6", "ufw6")):
        for name in ("INPUT", f"{prefix}-before-input", f"{prefix}-user-input"):
            items.append({"chain": {"family": family, "table": "filter", "name": name}})
        items.append({"rule": {"family": family, "table": "filter", "chain": "INPUT", "expr": [{"jump": {"target": f"{prefix}-before-input"}}]}})
        items.append({"rule": {"family": family, "table": "filter", "chain": f"{prefix}-before-input", "expr": [{"jump": {"target": f"{prefix}-user-input"}}]}})
        items.append({"rule": {"family": family, "table": "filter", "chain": f"{prefix}-user-input", "expr": [
            {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": gate.ORIGINAL_PORT}},
            {"accept": None},
        ]}})
    return {"nftables": items}


class GatePolicyTests(unittest.TestCase):
    """Verify that gate activation depends on an unchanged firewall policy."""

    def test_gate_rule_must_match_both_ports(self):
        """Reject a rule that could permit direct access to the shadow port."""
        document = rule_document()
        self.assertTrue(gate.gate_rule_present(document))
        document["nftables"][0]["rule"]["expr"][1]["match"]["right"] += 1
        self.assertFalse(gate.gate_rule_present(document))

    def test_fingerprint_ignores_counters_but_detects_policy_change(self):
        """Ignore packet counts while detecting changed filter rules."""
        rule = {"rule": {"family": "ip", "table": "filter", "chain": "INPUT", "handle": 2, "expr": [{"counter": {"packets": 1, "bytes": 40}}, {"accept": None}]}}
        document = {"nftables": [rule]}
        first = gate.firewall_fingerprint(document)
        rule["rule"]["expr"][0]["counter"]["packets"] = 100
        self.assertEqual(gate.firewall_fingerprint(document), first)
        rule["rule"]["expr"][-1] = {"drop": None}
        self.assertNotEqual(gate.firewall_fingerprint(document), first)

    def test_nat_changes_change_fingerprint(self):
        """Detect competing address translation rules in other tables."""
        document = {"nftables": []}
        first = gate.firewall_fingerprint(document)
        document["nftables"].append({"rule": {"family": "inet", "table": "other", "chain": "pre", "expr": [{"redirect": {"port": 1}}]}})
        self.assertNotEqual(gate.firewall_fingerprint(document), first)

    def test_gate_structure_rejects_extra_redirect(self):
        """Require one expected timed set and one narrowly scoped redirect."""
        table = gate.GATE_TABLE
        document = {"nftables": [
            {"table": {"family": "inet", "name": table}},
            {"set": {"family": "inet", "table": table, "name": gate.GATE_SET, "type": "inet_service", "flags": ["timeout"], "timeout": gate.GATE_TTL_SECONDS}},
            {"chain": {"family": "inet", "table": table, "name": "prerouting", "type": "nat", "hook": "prerouting", "prio": -100, "policy": "accept"}},
            {"rule": {"family": "inet", "table": table, "chain": "prerouting", "expr": [
                {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": f"@{gate.GATE_SET}"}},
                {"redirect": {"port": gate.MONITORED_PORT}},
            ]}},
        ]}
        self.assertTrue(gate.gate_structure_valid(document))
        document["nftables"].append(document["nftables"][-1])
        self.assertFalse(gate.gate_structure_valid(document))

    def test_stale_heartbeat_is_unhealthy(self):
        """Refuse activation when database persistence stops."""
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "traffic.sqlite3"
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE dashboard_collectorstatus (source text, heartbeat text)")
                old = datetime.now(timezone.utc) - timedelta(minutes=1)
                db.execute("INSERT INTO dashboard_collectorstatus VALUES (?, ?)", ("original", old.isoformat()))
            self.assertFalse(gate.collector_healthy(database))

    def test_setup_rejects_restrictive_or_changed_ufw_policy(self):
        """Require both original-port allow rules and reject extra denies."""
        document = ufw_document()
        gate_setup.validate_policy(document)
        document["nftables"][-1]["rule"]["expr"].append({"drop": None})
        with self.assertRaises(ValueError):
            gate_setup.validate_policy(document)


class GateWatchTests(unittest.IsolatedAsyncioTestCase):
    """Exercise dual-path health checks and automatic gate clearing."""

    async def test_stale_collector_clears_gate(self):
        """Activate only while both probes and persistence are healthy."""
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "traffic.sqlite3"
            status = Path(directory) / "status.json"
            original_config = Path(directory) / "original.json"
            original_config.write_text("original")
            original_hash = hashlib.sha256(original_config.read_bytes()).hexdigest()
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE dashboard_collectorstatus (source text, heartbeat text)")
                db.execute("INSERT INTO dashboard_collectorstatus VALUES (?, ?)", ("original", datetime.now(timezone.utc).isoformat()))
            counters = TestCounters()
            health_socket = socket.socket()
            health_socket.bind(("127.0.0.1", 0))
            health_port = health_socket.getsockname()[1]
            health_socket.close()
            handler = SocksServer(counters, health_port=health_port)
            first = await asyncio.start_server(handler.handle, "127.0.0.1", 0)
            second = await asyncio.start_server(handler.handle, "127.0.0.1", 0)
            ports = (first.sockets[0].getsockname()[1], second.sockets[0].getsockname()[1])
            refresh, clear = AsyncMock(), AsyncMock()
            with patch.object(gate, "ORIGINAL_CONFIG", original_config), patch.object(gate, "HEALTH_TARGET_PORT", health_port), patch.object(gate, "HEALTH_V4_PORT", ports[0]), patch.object(gate, "HEALTH_V6_PORT", ports[1]), patch.object(gate, "HEALTH_INTERVAL_SECONDS", .05), patch.object(gate, "firewall_ready", AsyncMock(return_value=True)), patch.object(gate, "refresh_gate", refresh), patch.object(gate, "clear_gate", clear):
                watcher = asyncio.create_task(gate.watch(database, True, status, "a" * 64, original_hash))
                try:
                    for _ in range(100):
                        if status.exists() and json.loads(status.read_text())["state"] == "active":
                            break
                        await asyncio.sleep(.02)
                    self.assertTrue(refresh.called)
                    self.assertEqual(sum(counters.values.values()), 0)
                    original_config.write_text("changed")
                    for _ in range(100):
                        if json.loads(status.read_text())["state"] == "fallback":
                            break
                        await asyncio.sleep(.02)
                    self.assertEqual(json.loads(status.read_text())["state"], "fallback")
                    original_config.write_text("original")
                    for _ in range(100):
                        if json.loads(status.read_text())["state"] == "active":
                            break
                        await asyncio.sleep(.02)
                    self.assertEqual(json.loads(status.read_text())["state"], "active")
                    with sqlite3.connect(database) as db:
                        db.execute("UPDATE dashboard_collectorstatus SET heartbeat = ?", ((datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat(),))
                    for _ in range(100):
                        if json.loads(status.read_text())["state"] == "fallback":
                            break
                        await asyncio.sleep(.02)
                    self.assertEqual(json.loads(status.read_text())["state"], "fallback")
                    self.assertTrue(clear.called)
                finally:
                    watcher.cancel()
                    with self.assertRaises(asyncio.CancelledError):
                        await asyncio.wait_for(watcher, timeout=5)
                    for server in (first, second):
                        server.close()
                    for task in list(handler.tasks):
                        task.cancel()
                    await asyncio.gather(*list(handler.tasks), return_exceptions=True)
                    await asyncio.gather(first.wait_closed(), second.wait_closed())
