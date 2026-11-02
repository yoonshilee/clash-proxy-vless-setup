"""Send recurring reports and remove expired traffic data."""

import logging
import time
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from dashboard.journal import ingest
from dashboard.models import AccessMinute, ReportSettings, TrafficMinute
from dashboard.reports import RETENTION_DAYS, scheduled_period, send

LOGGER = logging.getLogger(__name__)


def run_once(now):
    """Prune expired samples and send a due report at most once per period.

    Args:
        now: Timezone-aware current time.
    """
    TrafficMinute.objects.filter(minute__lt=now - timedelta(days=RETENTION_DAYS)).delete()
    AccessMinute.objects.filter(minute__lt=now - timedelta(days=RETENTION_DAYS)).delete()
    ingest()
    settings, _ = ReportSettings.objects.get_or_create(pk=1)
    period = scheduled_period(settings, now)
    if not period:
        return
    start, end = period
    key = f"{settings.frequency}:{start.isoformat()}:{end.isoformat()}"
    if key == settings.last_sent_period:
        return
    try:
        send(settings, start, end)
    except (OSError, ValueError) as exc:
        LOGGER.warning("Scheduled report failed: %s", type(exc).__name__)
        settings.last_error = f"Send failed: {type(exc).__name__}"
        settings.save(update_fields=["last_error"])
    else:
        settings.last_sent_period = key
        settings.last_error = ""
        settings.save(update_fields=["last_sent_period", "last_error"])


class Command(BaseCommand):
    """Run one scheduler instance for this dashboard."""

    help = "Run the traffic report scheduler."

    def handle(self, *args, **options):
        """Check the schedule periodically and retain the last 90 days.

        Args:
            *args: Positional management command arguments.
            **options: Management command options.
        """
        while True:
            run_once(timezone.now())
            time.sleep(60)
