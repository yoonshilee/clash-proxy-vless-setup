"""Persistent traffic samples and report settings."""

from django.db import models


class TrafficMinute(models.Model):
    """Count forwarded bytes for one destination and UTC minute."""

    minute = models.DateTimeField(db_index=True)
    domain = models.CharField(max_length=253)
    upload = models.BigIntegerField(default=0)
    download = models.BigIntegerField(default=0)

    class Meta:
        """Prevent duplicate domain and minute samples."""

        constraints = [models.UniqueConstraint(fields=["minute", "domain"], name="traffic_minute_domain")]


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
