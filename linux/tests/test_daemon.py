"""Unit tests for DaemonConfig and MonitorDaemon state transitions."""

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from obit_auth.config import DaemonConfig
from obit_auth.daemon import MonitorDaemon, active_wifi_connection


class TestDaemonConfig(unittest.TestCase):
    def test_load_toml_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = Path(tmp) / "config.toml"
            cfg_path.write_text(
                'check_interval_sec = 42\nssid_filter = "TEST_SSID"\nvpn_wait_sec = 6.5\n',
                encoding="utf-8",
            )
            cfg = DaemonConfig.load(cfg_path)
            self.assertEqual(cfg.check_interval_sec, 42)
            self.assertEqual(cfg.ssid_filter, "TEST_SSID")
            self.assertEqual(cfg.vpn_wait_sec, 6.5)

    def test_load_legacy_vpn_section_backwards_compatible(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = Path(tmp) / "config.toml"
            cfg_path.write_text(
                "[vpn]\nreconnect_wait_sec = 5.0\n",
                encoding="utf-8",
            )
            cfg = DaemonConfig.load(cfg_path)
            self.assertEqual(cfg.vpn_wait_sec, 5.0)


class TestMonitorDaemon(unittest.TestCase):
    def setUp(self) -> None:
        self.cfg = DaemonConfig(
            ssid_filter="NW_CAMPUS_by_OBIT",
            notify_on_success=True,
            notify_on_failure=True,
        )

    @mock.patch("obit_auth.daemon.subprocess.check_output", side_effect=FileNotFoundError("nmcli"))
    def test_active_wifi_connection_returns_none_when_nmcli_missing(self, _m_out) -> None:
        self.assertIsNone(active_wifi_connection())

    @mock.patch("obit_auth.daemon.subprocess.check_output", side_effect=subprocess.SubprocessError("fail"))
    def test_active_wifi_connection_returns_none_on_error(self, _m_out) -> None:
        self.assertIsNone(active_wifi_connection())

    @mock.patch("obit_auth.daemon.notify")
    @mock.patch("obit_auth.daemon.wait_for_default_route", return_value=True)
    @mock.patch(
        "obit_auth.daemon.run_portal_check",
        return_value={"status": "auth_success", "portal_url": "https://hspot.wifi.access5.obit.ru/confirm.php", "message": "ok"},
    )
    @mock.patch("obit_auth.daemon.active_wifi_connection", return_value="NW_CAMPUS_by_OBIT")
    @mock.patch("obit_auth.daemon.check_default_route_online", return_value=False)
    def test_auth_success_notifies(self, _m_fast, _m_wifi, _m_portal, _m_vpn, m_notify) -> None:
        daemon = MonitorDaemon(self.cfg)
        self.assertEqual(daemon.step(), "auth_success")
        m_notify.assert_called_once()

    @mock.patch("obit_auth.daemon.notify")
    @mock.patch(
        "obit_auth.daemon.run_portal_check",
        return_value={"status": "already_online", "portal_url": "", "message": "ok"},
    )
    @mock.patch("obit_auth.daemon.active_wifi_connection", return_value="NW_CAMPUS_by_OBIT")
    @mock.patch("obit_auth.daemon.check_default_route_online", return_value=False)
    def test_vpn_stalled_notifies_on_second_attempt_with_cooldown(
        self, _m_fast, _m_wifi, _m_portal, m_notify
    ) -> None:
        daemon = MonitorDaemon(self.cfg)
        self.assertEqual(daemon.step(), "vpn_stalled")
        m_notify.assert_not_called()
        self.assertEqual(daemon.step(), "vpn_stalled")
        m_notify.assert_called_once()
        self.assertEqual(daemon.step(), "vpn_stalled")
        m_notify.assert_called_once()  # anti-spam cooldown

    @mock.patch("obit_auth.daemon.notify")
    @mock.patch("obit_auth.daemon.active_wifi_connection", return_value="NW_CAMPUS_by_OBIT")
    @mock.patch("obit_auth.daemon.check_default_route_online", return_value=True)
    def test_manual_trigger_notifies_even_when_online(self, _m_fast, _m_wifi, m_notify) -> None:
        daemon = MonitorDaemon(self.cfg)
        self.assertEqual(daemon.step(manual_trigger=True), "online")
        m_notify.assert_called_once()

    @mock.patch("obit_auth.daemon.notify")
    @mock.patch(
        "obit_auth.daemon.run_portal_check",
        return_value={"status": "manual_required", "portal_url": "https://hspot.wifi.access5.obit.ru/stage2", "message": "sms"},
    )
    @mock.patch("obit_auth.daemon.active_wifi_connection", return_value="NW_CAMPUS_by_OBIT")
    @mock.patch("obit_auth.daemon.check_default_route_online", return_value=False)
    def test_manual_required_notifies_immediately(self, _m_fast, _m_wifi, _m_portal, m_notify) -> None:
        daemon = MonitorDaemon(self.cfg)
        self.assertEqual(daemon.step(), "manual_required")
        m_notify.assert_called_once()

    @mock.patch("obit_auth.daemon.run_portal_check")
    @mock.patch("obit_auth.daemon.active_wifi_connection", return_value="HOME_WIFI")
    @mock.patch("obit_auth.daemon.check_default_route_online", return_value=False)
    def test_ssid_filter_skips_other_networks(self, _m_fast, _m_wifi, m_portal) -> None:
        daemon = MonitorDaemon(self.cfg)
        self.assertEqual(daemon.step(), "ssid_filtered")
        m_portal.assert_not_called()

    @mock.patch("obit_auth.daemon.run_portal_check")
    @mock.patch("obit_auth.daemon.active_wifi_connection", return_value="HOME_WIFI")
    @mock.patch("obit_auth.daemon.check_default_route_online", return_value=True)
    def test_ssid_filter_skips_other_networks_even_when_online(self, m_fast, _m_wifi, m_portal) -> None:
        daemon = MonitorDaemon(self.cfg)
        self.assertEqual(daemon.step(), "ssid_filtered")
        self.assertEqual(daemon.snapshot().status, "ssid_filtered")
        self.assertEqual(daemon.snapshot().ssid, "HOME_WIFI")
        m_fast.assert_not_called()
        m_portal.assert_not_called()


if __name__ == "__main__":
    unittest.main()
