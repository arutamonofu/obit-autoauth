"""Cross-platform UI and state parity checks across Linux (Python), Windows (C#), and macOS (Swift)."""

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WIN_TRAY = REPO_ROOT / "windows" / "src" / "TrayApp.cs"
WIN_ENGINE = REPO_ROOT / "windows" / "src" / "MonitorEngine.cs"
MAC_APP = REPO_ROOT / "macos" / "src" / "AppDelegate.swift"
MAC_ENGINE = REPO_ROOT / "macos" / "src" / "MonitorEngine.swift"
LIN_TRAY = REPO_ROOT / "linux" / "src" / "obit_auth" / "tray.py"
LIN_DAEMON = REPO_ROOT / "linux" / "src" / "obit_auth" / "daemon.py"


class CrossPlatformParityTests(unittest.TestCase):
    def test_tray_menu_labels_match(self) -> None:
        win_tray = WIN_TRAY.read_text(encoding="utf-8")
        mac_app = MAC_APP.read_text(encoding="utf-8")
        lin_tray = LIN_TRAY.read_text(encoding="utf-8")

        shared_menu_labels = [
            "Открыть страницу входа",
            "Проверить и войти сейчас",
            "Запускать автоматически",
            "Показывать уведомления",
            "Открыть журнал работы",
            "Выход",
        ]
        for label in shared_menu_labels:
            self.assertIn(label, win_tray, f"Missing menu label in Windows TrayApp.cs: {label}")
            self.assertIn(label, mac_app, f"Missing menu label in macOS AppDelegate.swift: {label}")
            self.assertIn(label, lin_tray, f"Missing menu label in Linux tray.py: {label}")

    def test_status_texts_match_and_fit_windows_limit(self) -> None:
        win_engine = WIN_ENGINE.read_text(encoding="utf-8")
        mac_engine = MAC_ENGINE.read_text(encoding="utf-8")
        lin_tray = LIN_TRAY.read_text(encoding="utf-8")

        shared_statuses = [
            "Проверка входа...",
            "Авторизация активна",
            "Wi-Fi не подключён",
            "Вход есть, проверьте сеть или VPN",
            "Нужен вход вручную (телефон/SMS)",
            "Нужен вход в эту сеть Wi-Fi",
            "Нет связи с сетью",
            "Ошибка авторизации",
        ]
        for text in shared_statuses:
            self.assertLessEqual(len(text), 63, f"Status exceeds 63-char Windows NotifyIcon limit: {text}")
            self.assertIn(text, win_engine, f"Missing status in Windows MonitorEngine.cs: {text}")
            self.assertIn(text, mac_engine, f"Missing status in macOS MonitorEngine.swift: {text}")
            self.assertIn(text, lin_tray, f"Missing status in Linux tray.py: {text}")

    def test_notification_titles_match(self) -> None:
        win_all = WIN_ENGINE.read_text(encoding="utf-8") + "\n" + WIN_TRAY.read_text(encoding="utf-8")
        mac_all = MAC_ENGINE.read_text(encoding="utf-8") + "\n" + MAC_APP.read_text(encoding="utf-8")
        lin_all = LIN_DAEMON.read_text(encoding="utf-8") + "\n" + LIN_TRAY.read_text(encoding="utf-8")

        shared_titles = [
            "Авторизация активна",
            "Вход в ОБИТ выполнен",
            "Вход есть, но сеть не отвечает",
            "Нужен вход вручную (телефон/SMS)",
            "Нужен вход в эту сеть Wi-Fi",
            "Нет связи с сетью",
            "Ошибка авторизации",
            "Программа уже запущена.",
        ]
        for title in shared_titles:
            self.assertIn(title, win_all, f"Missing notification in Windows: {title}")
            self.assertIn(title, mac_all, f"Missing notification in macOS: {title}")
            self.assertIn(title, lin_all, f"Missing notification in Linux: {title}")


if __name__ == "__main__":
    unittest.main()
