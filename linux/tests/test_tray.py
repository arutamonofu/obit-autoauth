import tempfile
import unittest
from pathlib import Path
from unittest import mock

from obit_auth.config import DaemonConfig, set_notifications_enabled
from obit_auth.daemon import MonitorDaemon
from obit_auth.state import DaemonState, read_state, write_state
from obit_auth.tray import (
    acquire_single_instance_lock,
    ensure_tray_icons,
    format_tray_presentation,
    is_autostart_enabled,
    set_autostart_enabled,
)


class StateAndConfigTests(unittest.TestCase):
    def test_write_and_read_state_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_path = Path(tmp) / "state.json"
            original = DaemonState(
                status="online",
                auth_count=3,
                portal_url="",
                message="",
                ssid="OBIT_FREE",
                fail_streak=0,
                pid=12345,
                updated_at=1700000000.0,
            )
            write_state(original, state_path)
            loaded = read_state(state_path)
            self.assertIsNotNone(loaded)
            assert loaded is not None
            self.assertEqual(loaded.status, "online")
            self.assertEqual(loaded.auth_count, 3)
            self.assertEqual(loaded.ssid, "OBIT_FREE")
            self.assertEqual(loaded.pid, 12345)

    def test_set_notifications_enabled_updates_existing_toml(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = Path(tmp) / "config.toml"
            cfg_path.write_text(
                "# comment\n"
                "check_interval_sec = 15\n"
                "notify_on_success = true\n"
                "notify_on_failure = true\n\n"
                "[vpn]\n"
                'mode = "auto"\n',
                encoding="utf-8",
            )
            set_notifications_enabled(cfg_path, False)
            cfg = DaemonConfig.load(cfg_path)
            self.assertFalse(cfg.notify_on_success)
            self.assertFalse(cfg.notify_on_failure)
            self.assertIn("# comment", cfg_path.read_text(encoding="utf-8"))

            set_notifications_enabled(cfg_path, True)
            cfg2 = DaemonConfig.load(cfg_path)
            self.assertTrue(cfg2.notify_on_success)
            self.assertTrue(cfg2.notify_on_failure)

    def test_daemon_tracks_auth_count_and_portal_url_in_snapshot(self) -> None:
        cfg = DaemonConfig(notify_on_success=False, notify_on_failure=False)
        daemon = MonitorDaemon(cfg)

        with (
            mock.patch("obit_auth.daemon.check_default_route_online", return_value=False),
            mock.patch("obit_auth.daemon.active_wifi_connection", return_value="OBIT"),
            mock.patch(
                "obit_auth.daemon.run_portal_check",
                return_value={"status": "auth_success", "portal_url": "http://p", "message": ""},
            ),
            mock.patch("obit_auth.daemon.wait_for_default_route", return_value=True),
        ):
            self.assertEqual(daemon.step(), "auth_success")

        snap1 = daemon.snapshot()
        self.assertEqual(snap1.status, "auth_success")
        self.assertEqual(snap1.auth_count, 1)
        self.assertEqual(snap1.portal_url, "")

        with (
            mock.patch("obit_auth.daemon.check_default_route_online", return_value=False),
            mock.patch("obit_auth.daemon.active_wifi_connection", return_value="OBIT"),
            mock.patch(
                "obit_auth.daemon.run_portal_check",
                return_value={"status": "manual_required", "portal_url": "http://sms.obit.ru", "message": "SMS"},
            ),
        ):
            self.assertEqual(daemon.step(), "manual_required")

        snap2 = daemon.snapshot()
        self.assertEqual(snap2.status, "manual_required")
        self.assertEqual(snap2.portal_url, "http://sms.obit.ru")
        self.assertEqual(snap2.auth_count, 1)


class TrayHelpersTests(unittest.TestCase):
    def test_format_tray_presentation_states(self) -> None:
        self.assertEqual(format_tray_presentation(None, False), ("gray", "Автозащита остановлена", False))
        self.assertEqual(
            format_tray_presentation(DaemonState(status="checking"), True),
            ("gray", "Проверка подключения...", False),
        )
        self.assertEqual(
            format_tray_presentation(DaemonState(status="online", auth_count=0), True),
            ("green", "Интернет работает", False),
        )
        self.assertEqual(
            format_tray_presentation(DaemonState(status="online", auth_count=2), True),
            ("green", "Интернет работает (входов: 2)", False),
        )
        self.assertEqual(
            format_tray_presentation(DaemonState(status="wifi_disconnected"), True),
            ("gray", "Wi-Fi не подключён", False),
        )
        self.assertEqual(
            format_tray_presentation(DaemonState(status="vpn_stalled"), True),
            ("orange", "Wi-Fi работает, проверьте VPN", False),
        )
        self.assertEqual(
            format_tray_presentation(DaemonState(status="manual_required", portal_url="http://p"), True),
            ("red", "Нужен вход вручную (телефон/SMS)", True),
        )
        self.assertEqual(
            format_tray_presentation(DaemonState(status="unknown_portal", portal_url="http://u"), True),
            ("orange", "Нужен вход в эту сеть Wi-Fi", True),
        )
        self.assertEqual(
            format_tray_presentation(DaemonState(status="bypass_error"), True),
            ("orange", "Нет доступа в интернет", False),
        )

    def test_ensure_tray_icons_creates_four_svgs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            icons_dir = ensure_tray_icons(Path(tmp) / "icons")
            for color in ("gray", "green", "orange", "red"):
                p = icons_dir / f"obit-tray-{color}.svg"
                self.assertTrue(p.exists())
                self.assertIn("<svg", p.read_text(encoding="utf-8"))

    def test_autostart_toggle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            desktop = Path(tmp) / "autostart" / "obit-auto-auth-tray.desktop"
            self.assertFalse(is_autostart_enabled(desktop))
            set_autostart_enabled(True, desktop_path=desktop, exec_cmd="/usr/local/bin/obit-auth-tray")
            self.assertTrue(is_autostart_enabled(desktop))
            self.assertIn("Exec=/usr/local/bin/obit-auth-tray", desktop.read_text(encoding="utf-8"))
            set_autostart_enabled(False, desktop_path=desktop)
            self.assertFalse(is_autostart_enabled(desktop))

    def test_single_instance_lock(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            lock_path = Path(tmp) / "tray.lock"
            fh1 = acquire_single_instance_lock(lock_path)
            self.assertIsNotNone(fh1)
            fh2 = acquire_single_instance_lock(lock_path)
            self.assertIsNone(fh2)
            assert fh1 is not None
            fh1.close()


if __name__ == "__main__":
    unittest.main()
