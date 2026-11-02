"""Prepare an inactive nftables gate for original-node monitoring."""

import argparse
import json
import os
from pathlib import Path
import subprocess

from gate import GATE_COMMENT, GATE_SET, GATE_TABLE, GATE_TTL_SECONDS, chain_jumps, firewall_fingerprint
from prepare_original import MONITORED_PORT, ORIGINAL_PORT


def ruleset():
    """Read the current nftables policy without printing it."""
    output = subprocess.check_output(["nft", "-j", "list", "ruleset"], text=True, timeout=10)
    return json.loads(output)


def gate_rules():
    """Return an atomic, initially inactive dual-stack gate transaction."""
    return f'''table inet {GATE_TABLE} {{
 set {GATE_SET} {{ type inet_service; flags timeout; timeout {GATE_TTL_SECONDS}s; }}
 chain prerouting {{ type nat hook prerouting priority dstnat; policy accept; tcp dport @{GATE_SET} redirect to :{MONITORED_PORT}; }}
}}
insert rule ip filter ufw-user-input tcp dport {MONITORED_PORT} ct original proto-dst {ORIGINAL_PORT} accept comment "{GATE_COMMENT}"
insert rule ip6 filter ufw6-user-input tcp dport {MONITORED_PORT} ct original proto-dst {ORIGINAL_PORT} accept comment "{GATE_COMMENT}"
'''


def validate_policy(document):
    """Require the known permissive UFW policy before installing the gate.

    Args:
        document: Decoded nftables ruleset.
    """
    chains = {}
    for item in document.get("nftables", []):
        for kind in ("chain", "rule"):
            obj = item.get(kind)
            if not isinstance(obj, dict) or obj.get("table") != "filter" or obj.get("family") not in ("ip", "ip6"):
                continue
            name = obj.get("name") if kind == "chain" else obj.get("chain")
            chains.setdefault((obj["family"], name), []).append(item)
        table = item.get("table", {})
        if table.get("family") == "inet" and table.get("name") == GATE_TABLE:
            raise ValueError("The gate table already exists")
    for family, prefix in (("ip", "ufw"), ("ip6", "ufw6")):
        root = {"nftables": chains.get((family, "INPUT"), [])}
        before = {"nftables": chains.get((family, f"{prefix}-before-input"), [])}
        user = chains.get((family, f"{prefix}-user-input"), [])
        if f"{prefix}-before-input" not in chain_jumps(root) or f"{prefix}-user-input" not in chain_jumps(before):
            raise ValueError("The expected UFW input chain is not reachable")
        allow = False
        for item in user:
            if item.get("rule", {}).get("comment") == GATE_COMMENT:
                raise ValueError("A gate rule already exists")
            expr = item.get("rule", {}).get("expr", [])
            if any(key in element for element in expr for key in ("drop", "reject", "jump", "limit")):
                raise ValueError("The UFW user chain has unsupported restrictions")
            match = {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": ORIGINAL_PORT}
            if [element["match"] for element in expr if "match" in element] == [match] and any("accept" in element for element in expr):
                allow = True
        if not allow:
            raise ValueError("The original port is not unconditionally allowed by UFW")


def install(hash_path):
    """Install an inactive gate and save the pre-existing firewall fingerprint.

    Args:
        hash_path: New root-only fingerprint file.
    """
    if hash_path.exists():
        raise FileExistsError("The firewall fingerprint already exists")
    document = ruleset()
    validate_policy(document)
    digest = firewall_fingerprint(document)
    transaction = gate_rules()
    subprocess.run(["nft", "--check", "-f", "-"], input=transaction, text=True, check=True, timeout=10)
    fd = os.open(hash_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(digest + "\n")
        subprocess.run(["nft", "-f", "-"], input=transaction, text=True, check=True, timeout=10)
    except BaseException:
        hash_path.unlink(missing_ok=True)
        raise


def main():
    """Install only the inactive gate after an explicit command-line request."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--firewall-hash", type=Path, required=True)
    parser.add_argument("--install-inactive", action="store_true", required=True)
    args = parser.parse_args()
    install(args.firewall_hash)
    print("Inactive gate installed; no traffic is redirected.")


if __name__ == "__main__":
    main()
