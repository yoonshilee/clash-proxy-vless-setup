"""Authenticated dashboard and report views."""

from datetime import timedelta

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.utils import timezone
from django.views.decorators.http import require_POST

from .forms import RangeForm, ReportSettingsForm
from .models import ReportSettings
from .reports import collector_running, send, summarize


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
    rows = summarize(**form.cleaned_data) if form.is_valid() else []
    return render(request, "dashboard/index.html", {"form": form, "rows": rows, "upload": sum(row["upload"] for row in rows), "download": sum(row["download"] for row in rows), "collector_running": collector_running(timezone.now())})


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
