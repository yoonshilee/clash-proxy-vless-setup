"""Routes for the traffic dashboard."""

from django.contrib.auth import views as auth_views
from django.urls import path

from dashboard import views

urlpatterns = [
    path("login/", auth_views.LoginView.as_view(template_name="dashboard/login.html"), name="login"),
    path("logout/", auth_views.LogoutView.as_view(), name="logout"),
    path("", views.dashboard, name="dashboard"),
    path("settings/", views.settings, name="settings"),
    path("send/", views.send_report, name="send_report"),
]
