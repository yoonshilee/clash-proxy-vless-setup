"""Authenticated dashboard and report views."""

from datetime import timedelta

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.utils import timezone
from django.views.decorators.http import require_POST

from .forms import RangeForm, ReportSettingsForm
from .models import ReportSettings
from .constants import SOURCE_ORIGINAL
from .reports import collector_running, journal_running, original_gate_status, original_rows, send


def default_range():
    """Return a minute-aligned UTC range including the current minute."""
    end = timezone.now().replace(second=0, microsecond=0) + timedelta(minutes=1)
    return {"start": end - timedelta(days=1), "end": end}


@login_required
def dashboard(request):
    """Display traffic aggregated by domain for the selected time range.

    Args:
        request: Authenticated HTTP request.
    """
    form = RangeForm(request.GET if request.GET else None, initial=default_range())
    if not request.GET:
        form = RangeForm(default_range())
    valid = form.is_valid()
    access_rows = original_rows(**form.cleaned_data) if valid else []
    measured = [row["traffic"] for row in access_rows if row["traffic"] is not None]
    now = timezone.now()
    return render(request, "dashboard/index.html", {"form": form, "access_rows": access_rows, "measured": bool(measured), "upload": sum(row["upload"] for row in measured), "download": sum(row["download"] for row in measured), "original_collector_running": collector_running(now, source=SOURCE_ORIGINAL), "journal_running": journal_running(now), "gate_status": original_gate_status()})


@login_required
def settings(request):
    """Edit SMTP credentials and schedule for the single report.

    Args:
        request: Authenticated HTTP request.
    """
    obj, _ = ReportSettings.objects.get_or_create(pk=1)
    form = ReportSettingsForm(request.POST or None, instance=obj)
    if request.method == "POST" and form.is_valid():
        form.save()
        messages.success(request, "Report settings saved.")
        return redirect("settings")
    return render(request, "dashboard/settings.html", {"form": form, "last_error": obj.last_error})


@login_required
@require_POST
def send_report(request):
    """Send a report for the selected range after validating the request.

    Args:
        request: Authenticated HTTP request.
    """
    form = RangeForm(request.POST)
    if not form.is_valid():
        messages.error(request, "Select a valid reporting period.")
    else:
        obj, _ = ReportSettings.objects.get_or_create(pk=1)
        try:
            send(obj, **form.cleaned_data)
        except (OSError, ValueError):
            messages.error(request, "Report could not be sent. Check the SMTP settings.")
        else:
            messages.success(request, "Report sent.")
    return redirect("dashboard")
