"""Build reports and send them through the configured SMTP server."""

from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
import smtplib
import ssl
from zoneinfo import ZoneInfo

from django.db.models import Sum

from .models import CollectorStatus, TrafficMinute

RETENTION_DAYS = 90
HEARTBEAT_GRACE_SECONDS = 15


def collector_running(now):
    """Check whether the collector has recently persisted a heartbeat.

    Args:
        now: Timezone-aware current time.
    """
    status = CollectorStatus.objects.filter(pk=1).first()
    return bool(status and status.heartbeat and now - status.heartbeat < timedelta(seconds=HEARTBEAT_GRACE_SECONDS))


def summarize(start, end):
    """Return domain totals for the half-open UTC interval.

    Args:
        start: Inclusive start time.
        end: Exclusive end time.
    """
    rows = list(TrafficMinute.objects.filter(minute__gte=start, minute__lt=end).values("domain").annotate(upload=Sum("upload"), download=Sum("download")).order_by("-download", "domain"))
    rows.sort(key=lambda row: (-(row["upload"] + row["download"]), row["domain"]))
    return rows


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
    rows = summarize(start, end)
    upload = sum(row["upload"] for row in rows)
    download = sum(row["download"] for row in rows)
    state = "running" if collector_running(datetime.now(timezone.utc)) else "not reporting"
    lines = [f"Period: {start.isoformat()} to {end.isoformat()} (end exclusive)", f"Upload: {upload:,} bytes", f"Download: {download:,} bytes", f"Collector at send time: {state}", "Only the monitored node is included; outages may leave gaps.", "", "Top destinations:"]
    lines.extend(f"{row['domain']}: {row['upload']:,} up / {row['download']:,} down bytes" for row in rows[:20])
    unknown = next((row for row in rows[20:] if row["domain"] == "Unknown"), None)
    if unknown:
        lines.append(f"Unknown: {unknown['upload']:,} up / {unknown['download']:,} down bytes")
    if not rows:
        lines.append("No recorded traffic.")
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
