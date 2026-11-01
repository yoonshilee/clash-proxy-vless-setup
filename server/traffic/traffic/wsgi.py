"""WSGI entry point for the traffic dashboard."""

import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "traffic.settings")
application = get_wsgi_application()
