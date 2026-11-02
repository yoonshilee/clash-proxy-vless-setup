"""Build reports and send them through the configured SMTP server."""

from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
import json
from pathlib import Path
import smtplib
import ssl
import time
from zoneinfo import ZoneInfo

from django.db.models import Sum

from gate import GATE_TTL_SECONDS

from .constants import SOURCE_ORIGINAL, SOURCE_PREVIEW
from .models import AccessMinute, CollectorStatus, JournalState, TrafficMinute

RETENTION_DAYS = 90
HEARTBEAT_GRACE_SECONDS = 15
GATE_STATUS_PATH = Path("/run/clash-traffic-gate/status.json")
GATE_STATUS_GRACE_SECONDS = GATE_TTL_SECONDS


def original_gate_status():
    """Return a safe, human-readable state for original-node traffic routing."""
    try:
        status = json.loads(GATE_STATUS_PATH.read_text())
        age = time.time() - float(status["updated"])
        if age < 0 or age > GATE_STATUS_GRACE_SECONDS:
            return "not reporting"
        return {"active": "capturing new connections", "healthy": "shadow mode, not capturing", "shadow": "shadow checks pending", "fallback": "direct fallback"}.get(status["state"], "not reporting")
    except (OSError, ValueError, TypeError, KeyError):
        return "not reporting"


def collector_running(now, source=SOURCE_PREVIEW):
    """Check whether the collector has recently persisted a heartbeat.

    Args:
        now: Timezone-aware current time.
        source: Original or isolated preview node.
    """
    status = CollectorStatus.objects.filter(source=source).first()
    return bool(status and status.heartbeat and now - status.heartbeat < timedelta(seconds=HEARTBEAT_GRACE_SECONDS))


def summarize(start, end, source=SOURCE_PREVIEW):
    """Return domain totals for the half-open UTC interval.

    Args:
        start: Inclusive start time.
        end: Exclusive end time.
        source: Original or isolated preview node.
    """
    rows = list(TrafficMinute.objects.filter(source=source, minute__gte=start, minute__lt=end).values("domain").annotate(upload=Sum("upload"), download=Sum("download")).order_by("-download", "domain"))
    rows.sort(key=lambda row: (-(row["upload"] + row["download"]), row["domain"]))
    return rows


def summarize_access(start, end):
    """Return original-node connection counts for a UTC interval.

    Args:
        start: Inclusive start time.
        end: Exclusive end time.
    """
    return list(AccessMinute.objects.filter(minute__gte=start, minute__lt=end).values("domain").annotate(connections=Sum("connections")).order_by("-connections", "domain"))


def original_rows(start, end):
    """Combine original-node access counts with measured byte samples.

    Args:
        start: Inclusive start time.
        end: Exclusive end time.
    """
    traffic = {row["domain"]: row for row in summarize(start, end, source=SOURCE_ORIGINAL)}
    rows = summarize_access(start, end)
    for row in rows:
        row["traffic"] = traffic.pop(row["domain"], None)
    rows.extend({"domain": domain, "connections": None, "traffic": value} for domain, value in traffic.items())
    rows.sort(key=lambda row: (-(row["traffic"]["upload"] + row["traffic"]["download"]) if row["traffic"] else 0, -(row["connections"] or 0), row["domain"]))
    return rows


def journal_running(now):
    """Check whether the original-node journal was read recently.

    Args:
        now: Timezone-aware current time.
    """
    state = JournalState.objects.filter(pk=1).first()
    return bool(state and state.last_success and now - state.last_success < timedelta(minutes=3))


def send(settings, start, end):
    """Send a summary for a selected UTC interval using encrypted SMTP.

    Args:
        settings: Saved SMTP and recipient settings.
        start: Inclusive start time.
        end: Exclusive end time.
    """
    if not all((settings.host, settings.sender, settings.recipient)):
        raise ValueError("Configure the SMTP host, sender, and recipient first.")
    if settings.security not in ("starttls", "ssl"):
        raise ValueError("SMTP must use TLS or STARTTLS.")
    access_rows = original_rows(start, end)
    measured = [row["traffic"] for row in access_rows if row["traffic"] is not None]
    journal_state = "running" if journal_running(datetime.now(timezone.utc)) else "not reporting"
    lines = [f"Period: {start.isoformat()} to {end.isoformat()} (end exclusive)", f"Original-node journal at send time: {journal_state}", f"Traffic routing at send time: {original_gate_status()}", "Byte totals cover measured traffic only; outages or bypass may leave gaps."]
    if measured:
        lines.extend([f"Upload: {sum(row['upload'] for row in measured):,} bytes", f"Download: {sum(row['download'] for row in measured):,} bytes"])
    else:
        lines.append("Traffic totals unavailable.")
    lines.extend(["", "Original-node destinations by measured traffic:"])
    included = access_rows[:20]
    unknown = next((row for row in access_rows[20:] if row["domain"] == "Unknown"), None)
    if unknown:
        included = included + [unknown]
    for row in included:
        count = f"{row['connections']:,}" if row["connections"] is not None else "unavailable"
        traffic = row["traffic"]
        usage = f"{traffic['upload']:,} up / {traffic['download']:,} down bytes" if traffic else "byte counts unavailable"
        lines.append(f"{row['domain']}: {count} connections; {usage}")
    if not access_rows:
        lines.append("No original-node access records.")
    message = EmailMessage()
    message["Subject"] = "Proxy traffic report"
    message["From"] = settings.sender
    message["To"] = settings.recipient
    message.set_content("\n".join(lines))
    smtp_class = smtplib.SMTP_SSL if settings.security == "ssl" else smtplib.SMTP
    tls_context = ssl.create_default_context()
    kwargs = {"context": tls_context} if settings.security == "ssl" else {}
    with smtp_class(settings.host, settings.port, timeout=15, **kwargs) as smtp:
        if settings.security == "starttls":
            smtp.starttls(context=tls_context)
        if settings.username:
            smtp.login(settings.username, settings.password)
        smtp.send_message(message)


def scheduled_period(settings, now):
    """Return the most recently due complete period, or None when disabled.

    Args:
        settings: Saved report schedule.
        now: Timezone-aware current time.
    """
    if settings.frequency == "off":
        return None
    local = now.astimezone(ZoneInfo(settings.timezone))
    due = local.replace(hour=settings.hour, minute=settings.minute, second=0, microsecond=0)
    if settings.frequency == "weekly":
        due -= timedelta(days=(due.weekday() - settings.weekday) % 7)
        if due > local:
            due -= timedelta(days=7)
        end_date = due.date()
        start_date = end_date - timedelta(days=7)
    else:
        if due > local:
            due -= timedelta(days=1)
        end_date = due.date()
        start_date = end_date - timedelta(days=1)
    zone = ZoneInfo(settings.timezone)
    start = datetime.combine(start_date, datetime.min.time(), zone).astimezone(timezone.utc)
    end = datetime.combine(end_date, datetime.min.time(), zone).astimezone(timezone.utc)
    return start, end
