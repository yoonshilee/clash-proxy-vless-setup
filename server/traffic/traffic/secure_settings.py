"""Settings for the HTTPS dashboard behind the local Caddy socket."""

from datetime import timedelta
import os
import re

from .settings import *  # noqa: F403

PUBLIC_HOST = os.environ["TRAFFIC_PUBLIC_HOST"].lower().rstrip(".")
if len(PUBLIC_HOST) > 253 or not re.fullmatch(r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", PUBLIC_HOST):
    raise ValueError("TRAFFIC_PUBLIC_HOST must be a valid DNS hostname")

ALLOWED_HOSTS = [PUBLIC_HOST]
CSRF_TRUSTED_ORIGINS = [f"https://{PUBLIC_HOST}:{os.environ.get('TRAFFIC_HTTPS_PORT', '9443')}"]
INSTALLED_APPS += ["axes"]  # noqa: F405
MIDDLEWARE += ["axes.middleware.AxesMiddleware"]  # noqa: F405
AUTHENTICATION_BACKENDS = ["axes.backends.AxesStandaloneBackend", "django.contrib.auth.backends.ModelBackend"]
AXES_CLIENT_IP_CALLABLE = "traffic.security.client_ip"
AXES_FAILURE_LIMIT = 5
AXES_COOLOFF_TIME = timedelta(minutes=15)
AXES_RESET_ON_SUCCESS = True
AXES_DISABLE_ACCESS_LOG = True
AXES_VERBOSE = False
TRAFFIC_EXTERNAL_JOURNAL = True

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SECURE_SSL_REDIRECT = True
SECURE_HSTS_SECONDS = 31536000
SESSION_COOKIE_NAME = "vps_traffic_session"
SESSION_COOKIE_SECURE = True
SESSION_COOKIE_SAMESITE = "Strict"
SESSION_COOKIE_AGE = 43200
CSRF_COOKIE_NAME = "vps_traffic_csrf"
CSRF_COOKIE_SECURE = True
CSRF_COOKIE_SAMESITE = "Strict"
