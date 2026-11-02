"""Read the client address supplied by the local Caddy reverse proxy."""

import ipaddress

UNKNOWN_CLIENT = "0.0.0.0"


def client_ip(request):
    """Return Caddy's validated client address for login throttling.

    Args:
        request: The incoming Django request.

    Returns:
        A normalized IP address, or a shared fallback for invalid headers.
    """
    try:
        return str(ipaddress.ip_address(request.META.get("HTTP_X_TRAFFIC_CLIENT_IP", "")))
    except ValueError:
        return UNKNOWN_CLIENT
