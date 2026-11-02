"""Read original-node access records without changing Xray or its network path."""

from collections import Counter
from datetime import datetime, timezone
import ipaddress
import json
import logging
import re
import subprocess

from django.db import connection, transaction
from django.utils import timezone as django_timezone

from prepare_original import HEALTH_TARGET_PORT

from .models import JournalState

LOGGER = logging.getLogger(__name__)
MAX_RECORDS = 1000
JOURNAL_UNITS = ("xray.service", "clash-traffic-original.service")
ACCESS_TARGET = re.compile(r"\baccepted\s+(?:tcp|udp):(?P<host>\[[^\]]+\]|[^\s:]+):(?P<port>\d+)(?:\s|$)")
DOMAIN = re.compile(r"^[a-z0-9](?:[a-z0-9._-]{0,251}[a-z0-9])?$")


def access_record(entry):
    """Extract a UTC minute and destination from an Xray journal entry.

    Args:
        entry: Decoded systemd journal JSON object.

    Returns:
        A minute and destination, or None when the entry is not an access record.
    """
    message = entry.get("MESSAGE")
    match = ACCESS_TARGET.search(message) if isinstance(message, str) else None
    if not match:
        return None
    host = match.group("host").strip("[]").rstrip(".").lower()
    try:
        address = ipaddress.ip_address(host)
        if address.is_loopback and int(match.group("port")) == HEALTH_TARGET_PORT:
            return None
        domain = "Unknown"
    except ValueError:
        if not DOMAIN.fullmatch(host):
            return None
        domain = host
    try:
        minute = datetime.fromtimestamp(int(entry["__REALTIME_TIMESTAMP"]) / 1_000_000, tz=timezone.utc).replace(second=0, microsecond=0)
    except (KeyError, TypeError, ValueError, OverflowError, OSError):
        return None
    return minute, domain


def ingest():
    """Import a bounded batch of original-node access records and its cursor.

    The journal cursor and aggregated counts are committed together. A failed
    read leaves the last committed cursor in place for the next attempt.
    """
    state, _ = JournalState.objects.get_or_create(pk=1)
    command = ["journalctl"]
    for unit in JOURNAL_UNITS:
        command.extend(["--unit", unit])
    command.extend(["--output=json", "--output-fields=MESSAGE", "--no-pager", f"--lines={MAX_RECORDS}"])
    command.append(f"--after-cursor={state.cursor}" if state.cursor else "--since=-15 minutes")
    counts = Counter()
    last_cursor = state.cursor
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=20, check=True)
        for line in process.stdout.splitlines():
            entry = json.loads(line)
            cursor = entry.get("__CURSOR")
            if not isinstance(cursor, str) or not cursor:
                raise ValueError("Journal entry lacks a cursor")
            last_cursor = cursor
            item = access_record(entry)
            if item:
                counts[item] += 1
    except (OSError, ValueError, subprocess.SubprocessError):
        LOGGER.warning("Could not read original-node access records")
        return False
    with transaction.atomic():
        with connection.cursor() as cursor:
            cursor.executemany(
                "INSERT INTO dashboard_accessminute (minute, domain, connections) VALUES (%s, %s, %s) "
                "ON CONFLICT(minute, domain) DO UPDATE SET connections = connections + excluded.connections",
                [(minute.strftime("%Y-%m-%d %H:%M:%S"), domain, count) for (minute, domain), count in counts.items()],
            )
        state.cursor = last_cursor
        state.last_success = django_timezone.now()
        state.save(update_fields=["cursor", "last_success"])
    return True
