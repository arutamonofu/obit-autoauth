"""HTTP client for detecting and completing OBIT Wi-Fi captive portal login."""

from __future__ import annotations

import argparse
import html
import http.cookiejar
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from html.parser import HTMLParser
from typing import Sequence

from obit_auth.dns_resolver import dns_servers_from_env, scoped_dns_override

DEFAULT_PROBE_URL = "http://connectivitycheck.gstatic.com/generate_204"
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0"
)

_META_REFRESH_RE = re.compile(
    r'<meta[^>]+http-equiv=["\']?refresh["\']?[^>]+content=["\']?\d+\s*;\s*url=([^"\'>\s]+)',
    re.IGNORECASE,
)
_JS_LOCATION_RE = re.compile(
    r'(?:window\.location(?:\.href)?|location\.replace)\s*(?:=|\()\s*["\']([^"\']+)["\']',
    re.IGNORECASE,
)
_OBIT_SESS_RE = re.compile(r"OBIT_SessID=([a-zA-Z0-9_-]+)")
_CONNECT_BTN_RE = re.compile(
    r"""id=["']connect_btn["'][^>]*onclick=(?:"[^"]*?(confirm\.php\?[^"'\s]+)|'[^']*?(confirm\.php\?[^"'\s]+))""",
    re.IGNORECASE,
)


@dataclass
class ProbeResult:
    status: str  # "online" | "captive" | "offline"
    final_url: str = ""
    http_status: int = 0
    body: str = ""
    error: str = ""


@dataclass
class AuthResult:
    status: str  # "already_online" | "auth_success" | "unknown_portal" | "manual_required" | "offline" | "auth_failed"
    portal_url: str = ""
    message: str = ""


class _FormParser(HTMLParser):
    """Extract the first HTML form's action, method, and inputs."""

    def __init__(self) -> None:
        super().__init__()
        self.in_form = False
        self.action: str = ""
        self.method: str = "GET"
        self.fields: list[tuple[str, str]] = []
        self.found_form = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr_map = {k.lower(): (v or "") for k, v in attrs}
        if tag.lower() == "form" and not self.found_form:
            self.in_form = True
            self.found_form = True
            self.action = html.unescape(attr_map.get("action", ""))
            self.method = attr_map.get("method", "GET").upper()
        elif tag.lower() == "input" and self.in_form:
            name = attr_map.get("name", "")
            value = html.unescape(attr_map.get("value", ""))
            if name:
                self.fields.append((name, value))

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "form" and self.in_form:
            self.in_form = False


class PortalClient:
    """Stateless-friendly HTTP client with cookie jar and custom Wi-Fi DNS support."""

    def __init__(
        self,
        probe_url: str = DEFAULT_PROBE_URL,
        dns_servers: Sequence[str] | None = None,
        timeout: float = 5.0,
    ) -> None:
        self.probe_url = probe_url
        self.dns_servers = list(dns_servers) if dns_servers is not None else dns_servers_from_env()
        self.timeout = timeout
        self.cookies = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(self.cookies),
        )
        self.opener.addheaders = [("User-Agent", DEFAULT_USER_AGENT)]

    def _fetch(
        self,
        url: str,
        method: str = "GET",
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, str, str]:
        req = urllib.request.Request(url, data=data, method=method)
        if headers:
            for k, v in headers.items():
                req.add_header(k, v)
        with scoped_dns_override(self.dns_servers, timeout=min(self.timeout, 2.5)):
            with self.opener.open(req, timeout=self.timeout) as resp:
                status = getattr(resp, "status", resp.getcode())
                final_url = resp.geturl()
                raw = resp.read(512 * 1024)
                body = raw.decode("utf-8", errors="replace")
                return status, final_url, body

    def _follow_html_redirects(
        self, status: int, url: str, body: str, max_hops: int = 5
    ) -> tuple[int, str, str]:
        """Follow meta-refresh or simple JS location redirects used by hotspot gateways."""
        for _ in range(max_hops):
            if status == 204:
                return status, url, body
            next_target = None
            meta = _META_REFRESH_RE.search(body)
            if meta:
                next_target = html.unescape(meta.group(1))
            elif "confirm.php" not in url:
                js_loc = _JS_LOCATION_RE.search(body)
                if js_loc:
                    next_target = html.unescape(js_loc.group(1))
            if not next_target:
                break
            next_url = urllib.parse.urljoin(url, next_target)
            if next_url == url:
                break
            status, url, body = self._fetch(next_url)
        return status, url, body

    def probe(self) -> ProbeResult:
        """Check internet connectivity and detect captive portal redirection."""
        try:
            status, final_url, body = self._fetch(self.probe_url)
            status, final_url, body = self._follow_html_redirects(status, final_url, body)
        except urllib.error.HTTPError as exc:
            return ProbeResult(
                status="captive",
                final_url=exc.geturl() or self.probe_url,
                http_status=exc.code,
                error=str(exc),
            )
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            return ProbeResult(status="offline", error=str(exc))

        if status == 204:
            return ProbeResult(status="online", final_url=final_url, http_status=204)

        return ProbeResult(
            status="captive",
            final_url=final_url,
            http_status=status,
            body=body,
        )

    def _submit_auto_form_if_present(self, url: str, body: str) -> tuple[int, str, str] | None:
        """Submit an auto-login form (e.g., MikroTik hotspot POST) if stage3 returns one."""
        parser = _FormParser()
        parser.feed(body)
        if not parser.found_form or not parser.action:
            return None
        target = urllib.parse.urljoin(url, parser.action)
        encoded = urllib.parse.urlencode(parser.fields)
        if parser.method == "POST":
            return self._fetch(
                target,
                method="POST",
                data=encoded.encode("utf-8"),
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
        sep = "&" if "?" in target else "?"
        return self._fetch(f"{target}{sep}{encoded}" if encoded else target)

    def authorize_if_needed(self) -> AuthResult:
        """Probe connectivity and complete OBIT stage1 -> ajx_check -> stage3 flow if needed."""
        probe = self.probe()
        if probe.status == "online":
            return AuthResult(status="already_online", message="Network is online")
        if probe.status == "offline":
            return AuthResult(status="offline", message=probe.error or "Network unreachable")

        portal_url = probe.final_url
        body = probe.body
        parsed = urllib.parse.urlparse(portal_url)
        is_obit = "obit.ru" in parsed.netloc.lower() or "OBIT_SessID" in body or "OBIT_SessID" in portal_url

        if not is_obit:
            return AuthResult(
                status="unknown_portal",
                portal_url=portal_url,
                message=f"Redirected to non-OBIT portal: {portal_url}",
            )

        sess_match = _OBIT_SESS_RE.search(portal_url) or _OBIT_SESS_RE.search(body)
        btn_match = _CONNECT_BTN_RE.search(body)

        if not btn_match:
            if 'id="call_btn"' in body or "stage=stage2" in body or 'type="tel"' in body:
                return AuthResult(
                    status="manual_required",
                    portal_url=portal_url,
                    message="OBIT portal requires phone/SMS verification",
                )
            return AuthResult(
                status="auth_failed",
                portal_url=portal_url,
                message="Could not find connect button on OBIT portal page",
            )

        if not sess_match:
            return AuthResult(
                status="auth_failed",
                portal_url=portal_url,
                message="Could not extract OBIT_SessID",
            )

        sess_id = sess_match.group(1)
        stage3_rel = html.unescape(btn_match.group(1) or btn_match.group(2))
        ajx_url = urllib.parse.urljoin(
            portal_url,
            f"confirm.php?stage=ajx_check&OBIT_SessID={sess_id}&width=1920&height=1080",
        )
        stage3_url = urllib.parse.urljoin(portal_url, stage3_rel)

        try:
            self._fetch(
                ajx_url,
                headers={"X-Requested-With": "XMLHttpRequest", "Referer": portal_url},
            )
            st3_code, st3_url, st3_body = self._fetch(
                stage3_url,
                headers={"Referer": portal_url},
            )
            st3_code, st3_url, st3_body = self._follow_html_redirects(
                st3_code, st3_url, st3_body
            )
            if st3_code != 204:
                self._submit_auto_form_if_present(st3_url, st3_body)
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            return AuthResult(
                status="auth_failed",
                portal_url=portal_url,
                message=f"Error during OBIT stage3 request: {exc}",
            )

        verify = self.probe()
        if verify.status == "online":
            return AuthResult(
                status="auth_success",
                portal_url=portal_url,
                message="OBIT Wi-Fi authorization succeeded",
            )

        return AuthResult(
            status="auth_failed",
            portal_url=portal_url,
            message=f"Post-auth probe returned {verify.status} ({verify.http_status}): {verify.error}",
        )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="OBIT Wi-Fi captive portal client")
    parser.add_argument("--probe-only", action="store_true", help="Only probe connectivity")
    parser.add_argument("--probe-url", default=DEFAULT_PROBE_URL)
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)

    client = PortalClient(probe_url=args.probe_url, timeout=args.timeout)
    if args.probe_only:
        res = client.probe()
        payload = asdict(res)
        payload.pop("body", None)
        print(json.dumps(payload, ensure_ascii=False))
        return 0 if res.status == "online" else 1

    res = client.authorize_if_needed()
    print(json.dumps(asdict(res), ensure_ascii=False))
    return 0 if res.status in {"already_online", "auth_success"} else 1


if __name__ == "__main__":
    sys.exit(main())
