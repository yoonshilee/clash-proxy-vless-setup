"""Read Xray access records as a separate, journal-authorized service."""

import time

from django.core.management.base import BaseCommand

from dashboard.journal import ingest

JOURNAL_INTERVAL_SECONDS = 60


class Command(BaseCommand):
    """Import journal records without granting the web process journal access."""

    def handle(self, *args, **options):
        """Run the journal reader until the service stops.

        Args:
            *args: Positional command arguments.
            **options: Parsed command options.
        """
        while True:
            ingest()
            time.sleep(JOURNAL_INTERVAL_SECONDS)
