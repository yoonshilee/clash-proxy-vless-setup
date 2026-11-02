"""Persistent traffic samples and report settings."""

from django.db import models

from .constants import SOURCE_PREVIEW


class TrafficMinute(models.Model):
    """Count forwarded bytes for one destination and UTC minute."""

    minute = models.DateTimeField(db_index=True)
    domain = models.CharField(max_length=253)
    source = models.CharField(max_length=16, default=SOURCE_PREVIEW)
    upload = models.BigIntegerField(default=0)
    download = models.BigIntegerField(default=0)

    class Meta:
        """Prevent duplicate domain and minute samples."""

        constraints = [models.UniqueConstraint(fields=["source", "minute", "domain"], name="traffic_source_minute_domain")]


class ReportSettings(models.Model):
    """Hold private SMTP settings and a single report schedule."""

    host = models.CharField(max_length=253, blank=True)
    port = models.PositiveIntegerField(default=587)
    username = models.CharField(max_length=254, blank=True)
    password = models.CharField(max_length=512, blank=True)
    sender = models.EmailField(blank=True)
    recipient = models.EmailField(blank=True)
    security = models.CharField(max_length=8, default="starttls")
    frequency = models.CharField(max_length=8, default="off")
    hour = models.PositiveSmallIntegerField(default=0)
    minute = models.PositiveSmallIntegerField(default=0)
    weekday = models.PositiveSmallIntegerField(default=0)
    timezone = models.CharField(max_length=64, default="UTC")
    last_sent_period = models.CharField(max_length=64, blank=True)
    last_error = models.CharField(max_length=500, blank=True)


class CollectorStatus(models.Model):
    """Record the latest successful collector persistence heartbeat."""

    heartbeat = models.DateTimeField(null=True)
    source = models.CharField(max_length=16, unique=True, default=SOURCE_PREVIEW)


class AccessMinute(models.Model):
    """Count original-node connections by destination and UTC minute."""

    minute = models.DateTimeField(db_index=True)
    domain = models.CharField(max_length=253)
    connections = models.BigIntegerField(default=0)

    class Meta:
        """Prevent duplicate access samples."""

        constraints = [models.UniqueConstraint(fields=["minute", "domain"], name="access_minute_domain")]


class JournalState(models.Model):
    """Persist the original-node journal cursor and latest successful read."""

    cursor = models.TextField(blank=True)
    last_success = models.DateTimeField(null=True)
