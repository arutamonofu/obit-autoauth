"""Default route (VPN) connectivity probe helpers."""

from __future__ import annotations

import time
import urllib.error
import urllib.request

from obit_auth.dns_resolver import scoped_dns_override
from obit_auth.portal_client import DEFAULT_PROBE_URL


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[override]
        return None


_FAST_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


def check_default_route_online(
    url: str = DEFAULT_PROBE_URL,
    timeout: float = 2.5,
) -> bool:
    """Fast IPv4-only check whether internet returns HTTP 204 via current default route."""
    req = urllib.request.Request(url, method="GET")
    try:
        with scoped_dns_override(None, timeout=timeout):
            with _FAST_OPENER.open(req, timeout=timeout) as resp:
                return getattr(resp, "status", resp.getcode()) == 204
    except (urllib.error.URLError, OSError, TimeoutError):
        return False


def wait_for_default_route(
    url: str = DEFAULT_PROBE_URL,
    timeout_sec: float = 4.0,
) -> bool:
    """Wait briefly after portal login for the default route / VPN tunnel to recover."""
    deadline = time.monotonic() + max(0.5, timeout_sec)
    while time.monotonic() < deadline:
        if check_default_route_online(url=url, timeout=2.0):
            return True
        time.sleep(0.75)
    return False
