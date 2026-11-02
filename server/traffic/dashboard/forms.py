"""Forms for report settings and UTC time ranges."""

from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from django import forms

from .models import ReportSettings


class RangeForm(forms.Form):
    """Validate a report interval in UTC."""

    start = forms.DateTimeField(widget=forms.DateTimeInput(format="%Y-%m-%d %H:%M", attrs={"placeholder": "YYYY-MM-DD HH:MM", "autocomplete": "off"}))
    end = forms.DateTimeField(widget=forms.DateTimeInput(format="%Y-%m-%d %H:%M", attrs={"placeholder": "YYYY-MM-DD HH:MM", "autocomplete": "off"}))

    def clean(self):
        """Require an increasing, minute-aligned interval."""
        values = super().clean()
        start, end = values.get("start"), values.get("end")
        if start and end and (start >= end or start.second or end.second or start.microsecond or end.microsecond):
            raise forms.ValidationError("Select a valid minute-aligned range.")
        return values


class ReportSettingsForm(forms.ModelForm):
    """Validate SMTP credentials and the recurring report schedule."""

    password = forms.CharField(required=False, widget=forms.PasswordInput(render_value=False), help_text="Leave blank to keep the current password.")
    security = forms.ChoiceField(choices=[("starttls", "STARTTLS"), ("ssl", "TLS")])
    frequency = forms.ChoiceField(choices=[("off", "Off"), ("daily", "Daily"), ("weekly", "Weekly")])
    weekday = forms.TypedChoiceField(coerce=int, choices=[(i, day) for i, day in enumerate(("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"))])

    def __init__(self, *args, **kwargs):
        """Remember the stored password before model form validation.

        Args:
            *args: Positional form arguments.
            **kwargs: Keyword form arguments.
        """
        super().__init__(*args, **kwargs)
        self.original_password = self.instance.password

    class Meta:
        """Expose the settings needed by a single administrator."""

        model = ReportSettings
        fields = ("host", "port", "username", "password", "sender", "recipient", "security", "frequency", "hour", "minute", "weekday", "timezone")

    def clean_timezone(self):
        """Require a valid IANA time zone."""
        value = self.cleaned_data["timezone"]
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError):
            raise forms.ValidationError("Enter a valid IANA time zone.")
        return value

    def clean(self):
        """Validate the schedule, port, and SMTP fields."""
        data = super().clean()
        if not 1 <= data.get("port", 0) <= 65535:
            self.add_error("port", "Enter a port between 1 and 65535.")
        if data.get("hour", 24) > 23 or data.get("minute", 60) > 59:
            raise forms.ValidationError("Enter a valid sending time.")
        if data.get("frequency") != "off" and not all(data.get(field) for field in ("host", "sender", "recipient")):
            raise forms.ValidationError("Set the SMTP host, sender, and recipient before enabling a schedule.")
        return data

    def save(self, commit=True):
        """Keep the existing SMTP password when the password field is blank.

        Args:
            commit: Whether to save the model immediately.
        """
        settings = super().save(commit=False)
        if not self.cleaned_data["password"]:
            settings.password = self.original_password
        if commit:
            settings.save()
        return settings
