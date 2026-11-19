"""Unit tests for OBIT captive portal client using an in-process mock HTTP server."""

import html
import http.server
import threading
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock

from obit_auth.config import DaemonConfig
from obit_auth.daemon import MonitorDaemon
from obit_auth.portal_client import PortalClient, _CONNECT_BTN_RE, _OBIT_SESS_RE


class _PortalState:
    def __init__(self, mode: str = "obit_stage1") -> None:
        self.mode = mode
        self.authorized = False
        self.ajx_called = False
        self.stage3_called = False
        self.form_posted = False


def _make_handler(state: _PortalState):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:  # noqa: A002
            return

        def do_GET(self) -> None:  # noqa: N802
            parsed = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(parsed.query)

            if parsed.path == "/generate_204":
                if state.mode == "online" or state.authorized:
                    self.send_response(204)
                    self.end_headers()
                    return
                if state.mode == "unknown_portal":
                    self.send_response(302)
                    self.send_header("Location", "/other-hotspot/login")
                    self.end_headers()
                    return
                self.send_response(302)
                self.send_header(
                    "Location",
                    "/obit_direct_2025/confirm.php?stage=stage1&OBIT_SessID=test_sess_123",
                )
                self.end_headers()
                return

            if parsed.path == "/other-hotspot/login":
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"<html><body><h1>Some Cafe Wi-Fi</h1></body></html>")
                return

            if parsed.path == "/obit_direct_2025/confirm.php":
                stage = qs.get("stage", [""])[0]
                if stage == "stage1":
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.end_headers()
                    if state.mode == "manual_required":
                        html_body = (
                            '<form id="stage1">'
                            '<input type="tel" name="phone">'
                            '<button id="call_btn">Call</button>'
                            "</form>"
                        )
                    else:
                        html_body = (
                            "<h4>Вы уже зарегистрированы в сети WiFi оператора ОБИТ</h4>"
                            '<button id="connect_btn" '
                            "onclick=\"window.location = 'confirm.php?stage=stage3&amp;OBIT_SessID=test_sess_123';\">"
                            "Подключиться</button>"
                        )
                    self.wfile.write(html_body.encode("utf-8"))
                    return

                if stage == "ajx_check":
                    state.ajx_called = True
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"ok")
                    return

                if stage == "stage3":
                    state.stage3_called = True
                    if state.mode == "obit_stage3_form":
                        self.send_response(200)
                        self.send_header("Content-Type", "text/html; charset=utf-8")
                        self.end_headers()
                        self.wfile.write(
                            b'<form action="/router/login" method="POST">'
                            b'<input type="hidden" name="token" value="abc">'
                            b"</form>"
                        )
                        return
                    state.authorized = True
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"Connected")
                    return

            self.send_response(404)
            self.end_headers()

        def do_POST(self) -> None:  # noqa: N802
            if self.path == "/router/login":
                length = int(self.headers.get("Content-Length", "0"))
                _ = self.rfile.read(length)
                state.form_posted = True
                state.authorized = True
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
                return
            self.send_response(404)
            self.end_headers()

    return Handler


class TestPortalClient(unittest.TestCase):
    def _run_with_state(self, state: _PortalState):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _make_handler(state))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        client = PortalClient(probe_url=f"http://127.0.0.1:{port}/generate_204", dns_servers=[])
        return server, client

    def test_already_online(self) -> None:
        state = _PortalState(mode="online")
        server, client = self._run_with_state(state)
        try:
            res = client.authorize_if_needed()
            self.assertEqual(res.status, "already_online")
        finally:
            server.shutdown()
            server.server_close()

    def test_obit_stage1_to_stage3_success(self) -> None:
        state = _PortalState(mode="obit_stage1")
        server, client = self._run_with_state(state)
        try:
            res = client.authorize_if_needed()
            self.assertEqual(res.status, "auth_success")
            self.assertTrue(state.ajx_called)
            self.assertTrue(state.stage3_called)
            self.assertTrue(state.authorized)
        finally:
            server.shutdown()
            server.server_close()

    def test_obit_stage3_with_auto_form_post(self) -> None:
        state = _PortalState(mode="obit_stage3_form")
        server, client = self._run_with_state(state)
        try:
            res = client.authorize_if_needed()
            self.assertEqual(res.status, "auth_success")
            self.assertTrue(state.form_posted)
            self.assertTrue(state.authorized)
        finally:
            server.shutdown()
            server.server_close()

    def test_manual_required_phone_form(self) -> None:
        state = _PortalState(mode="manual_required")
        server, client = self._run_with_state(state)
        try:
            res = client.authorize_if_needed()
            self.assertEqual(res.status, "manual_required")
        finally:
            server.shutdown()
            server.server_close()

    def test_unknown_portal(self) -> None:
        state = _PortalState(mode="unknown_portal")
        server, client = self._run_with_state(state)
        try:
            res = client.authorize_if_needed()
            self.assertEqual(res.status, "unknown_portal")
        finally:
            server.shutdown()
            server.server_close()

    def test_daemon_fast_path_skips_sudo_when_online(self) -> None:
        state = _PortalState(mode="online")
        server, client = self._run_with_state(state)
        try:
            cfg = DaemonConfig(probe_url=client.probe_url, notify_on_success=False, notify_on_failure=False)
            daemon = MonitorDaemon(cfg)
            with mock.patch("obit_auth.daemon.run_portal_check") as m_bypass:
                self.assertEqual(daemon.step(), "online")
                m_bypass.assert_not_called()
        finally:
            server.shutdown()
            server.server_close()

    def test_sanitized_obit_fixture_parsing(self) -> None:
        fixture = Path(__file__).parent / "fixtures" / "obit_stage1.html"
        content = fixture.read_text(encoding="utf-8")
        sess = _OBIT_SESS_RE.search(content)
        btn = _CONNECT_BTN_RE.search(content)
        self.assertIsNotNone(sess)
        self.assertIsNotNone(btn)
        self.assertEqual(sess.group(1), "0000000000000000000000000000dead")
        stage3 = html.unescape(btn.group(1) or btn.group(2))
        self.assertEqual(stage3, "confirm.php?stage=stage3&OBIT_SessID=0000000000000000000000000000dead")


if __name__ == "__main__":
    unittest.main()
