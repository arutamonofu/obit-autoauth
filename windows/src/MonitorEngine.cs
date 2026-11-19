using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ObitAutoAuth
{
    internal enum AppStatus
    {
        Checking,
        Online,
        WifiDisconnected,
        VpnStalled,
        ManualRequired,
        UnknownPortal,
        Offline,
        Error
    }

    internal sealed class UiPresentation
    {
        public Color DotColor;
        public string StatusText;
        public string PortalUrl;
        public bool ShowPortalAction;
    }

    internal sealed class NotificationRequest
    {
        public string Key;
        public string Title;
        public string Text;
        public ToolTipIcon Icon;
        public bool Force;
    }

    internal sealed class Logger
    {
        private readonly string _logPath;
        private readonly object _lock = new object();

        public Logger(string appDir)
        {
            Directory.CreateDirectory(appDir);
            _logPath = Path.Combine(appDir, "obit-auth.log");
        }

        public string LogPath
        {
            get { return _logPath; }
        }

        public void Info(string message) { Write("INFO", message); }
        public void Warn(string message) { Write("WARN", message); }
        public void Error(string message) { Write("ERROR", message); }

        private void Write(string level, string message)
        {
            lock (_lock)
            {
                try
                {
                    FileInfo fi = new FileInfo(_logPath);
                    if (fi.Exists && fi.Length > 512 * 1024)
                    {
                        string oldPath = _logPath + ".old";
                        if (File.Exists(oldPath)) File.Delete(oldPath);
                        File.Move(_logPath, oldPath);
                    }
                    string line = string.Format("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}{3}",
                        DateTime.Now, level, message, Environment.NewLine);
                    File.AppendAllText(_logPath, line, Encoding.UTF8);
                }
                catch
                {
                    // Ignore logging I/O errors
                }
            }
        }
    }

    internal sealed class AppSettings
    {
        private readonly string _appDir;
        private readonly string _settingsPath;

        public bool NotificationsEnabled = true;
        public bool WelcomeShown = false;

        public AppSettings(string appDir)
        {
            _appDir = appDir;
            _settingsPath = Path.Combine(appDir, "settings.ini");
        }

        public void Load()
        {
            try
            {
                if (!File.Exists(_settingsPath)) return;
                string content = File.ReadAllText(_settingsPath, Encoding.UTF8);
                NotificationsEnabled = content.IndexOf("notify=0", StringComparison.Ordinal) < 0;
                WelcomeShown = content.IndexOf("welcome=1", StringComparison.Ordinal) >= 0;
            }
            catch
            {
                // Keep defaults
            }
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(_appDir);
                string content = string.Format("notify={0}{1}welcome={2}{1}",
                    NotificationsEnabled ? "1" : "0",
                    Environment.NewLine,
                    WelcomeShown ? "1" : "0");
                File.WriteAllText(_settingsPath, content, Encoding.UTF8);
            }
            catch
            {
                // Ignore settings I/O errors
            }
        }
    }

    internal sealed class MonitorEngine
    {
        private readonly Logger _log;
        private readonly Action<UiPresentation> _onStateChanged;
        private readonly Action<NotificationRequest> _onNotify;

        private int _authCount = 0;
        private int _failStreak = 0;

        public MonitorEngine(
            Logger log,
            Action<UiPresentation> onStateChanged,
            Action<NotificationRequest> onNotify)
        {
            _log = log;
            _onStateChanged = onStateChanged;
            _onNotify = onNotify;
        }

        public static UiPresentation FormatPresentation(AppStatus status, int authCount, string portalUrl)
        {
            UiPresentation p = new UiPresentation();
            p.PortalUrl = portalUrl ?? string.Empty;
            p.ShowPortalAction = false;

            switch (status)
            {
                case AppStatus.Checking:
                    p.DotColor = Color.Gray;
                    p.StatusText = "Проверка подключения...";
                    break;
                case AppStatus.Online:
                    p.DotColor = Color.LimeGreen;
                    p.StatusText = authCount <= 0
                        ? "Интернет работает"
                        : string.Format("Интернет работает (входов: {0})", authCount);
                    break;
                case AppStatus.WifiDisconnected:
                    p.DotColor = Color.Gray;
                    p.StatusText = "Wi-Fi не подключён";
                    break;
                case AppStatus.VpnStalled:
                    p.DotColor = Color.Orange;
                    p.StatusText = "Wi-Fi работает, проверьте VPN";
                    break;
                case AppStatus.ManualRequired:
                    p.DotColor = Color.Crimson;
                    p.StatusText = "Нужен вход вручную (телефон/SMS)";
                    p.ShowPortalAction = !string.IsNullOrEmpty(p.PortalUrl);
                    break;
                case AppStatus.UnknownPortal:
                    p.DotColor = Color.Orange;
                    p.StatusText = "Нужен вход в эту сеть Wi-Fi";
                    p.ShowPortalAction = !string.IsNullOrEmpty(p.PortalUrl);
                    break;
                default:
                    p.DotColor = Color.Orange;
                    p.StatusText = "Нет доступа в интернет";
                    break;
            }
            return p;
        }

        public void RunCheckCycle(bool forceBypass, bool manualTrigger)
        {
            if (manualTrigger)
            {
                EmitState(AppStatus.Checking, string.Empty);
            }

            if (!forceBypass && ObitPortalClient.FastPathDefaultOnline())
            {
                if (_failStreak > 0)
                {
                    _log.Info("Connectivity restored (failStreak was " + _failStreak + ")");
                }
                _failStreak = 0;
                EmitState(AppStatus.Online, string.Empty);
                if (manualTrigger)
                {
                    EmitNotify("online", "Подключение работает",
                        "Интернет и VPN в порядке, вход не требуется.",
                        ToolTipIcon.Info, true);
                }
                return;
            }

            WifiAdapterInfo wifi = WifiAdapterInfo.DetectActive();
            if (wifi == null)
            {
                _failStreak = 0;
                EmitState(AppStatus.WifiDisconnected, string.Empty);
                if (manualTrigger)
                {
                    EmitNotify("wifi_off", "Wi-Fi не подключён",
                        "Подключитесь к сети Wi-Fi и повторите проверку.",
                        ToolTipIcon.Warning, true);
                }
                return;
            }

            _failStreak++;
            Stopwatch sw = Stopwatch.StartNew();
            PortalCheckResult res = ObitPortalClient.CheckAndAuthorize(wifi);
            sw.Stop();

            if (res.Outcome == PortalOutcome.AuthSuccess)
            {
                _authCount++;
                _failStreak = 0;
                bool vpnOk = WaitForDefaultRoute(4000);
                _log.Info(string.Format("Re-authorized via {0} in {1:F2}s (vpn_online={2})",
                    wifi.Name, sw.Elapsed.TotalSeconds, vpnOk));
                EmitState(AppStatus.Online, string.Empty);
                string suffix = vpnOk ? "VPN работает." : "Проверьте VPN: туннель пока не отвечает.";
                EmitNotify("auth_ok", "Wi-Fi ОБИТ подключён",
                    string.Format("Повторный вход выполнен за {0:F1} с. {1}", sw.Elapsed.TotalSeconds, suffix),
                    ToolTipIcon.Info, manualTrigger);
                return;
            }

            if (res.Outcome == PortalOutcome.AlreadyOnline)
            {
                if (ObitPortalClient.FastPathDefaultOnline())
                {
                    _failStreak = 0;
                    EmitState(AppStatus.Online, string.Empty);
                    if (manualTrigger)
                    {
                        EmitNotify("online", "Подключение работает",
                            "Интернет и VPN в порядке, вход не требуется.",
                            ToolTipIcon.Info, true);
                    }
                    return;
                }

                _log.Warn(string.Format("Wi-Fi '{0}' is online via bypass, but default route/VPN is stalled", wifi.Name));
                EmitState(AppStatus.VpnStalled, string.Empty);
                if (manualTrigger || _failStreak >= 2)
                {
                    EmitNotify("vpn_stalled", "Wi-Fi работает, но VPN не отвечает",
                        "Подключите или перезапустите VPN.",
                        ToolTipIcon.Warning, manualTrigger);
                }
                return;
            }

            if (res.Outcome == PortalOutcome.ManualRequired)
            {
                _log.Warn("Manual verification required: " + res.PortalUrl);
                EmitState(AppStatus.ManualRequired, res.PortalUrl);
                EmitNotify("manual", "Нужен вход вручную (телефон/SMS)",
                    "Нажмите на уведомление или выберите «Открыть страницу входа» в меню значка.",
                    ToolTipIcon.Warning, manualTrigger);
                return;
            }

            if (res.Outcome == PortalOutcome.UnknownPortal)
            {
                _log.Info("Unknown portal: " + res.PortalUrl);
                EmitState(AppStatus.UnknownPortal, res.PortalUrl);
                EmitNotify("unknown:" + res.PortalUrl, "Нужен вход в эту сеть Wi-Fi",
                    "Нажмите на уведомление или выберите «Открыть страницу входа» в меню значка.",
                    ToolTipIcon.Info, manualTrigger);
                return;
            }

            _log.Warn("Bypass check failed (" + res.Outcome + "): " + res.Message);
            EmitState(res.Outcome == PortalOutcome.Offline ? AppStatus.Offline : AppStatus.Error, string.Empty);
            if (manualTrigger || _failStreak >= 2)
            {
                EmitNotify("err", "Нет доступа в интернет",
                    "Проверьте подключение к Wi-Fi или роутеру.",
                    ToolTipIcon.Error, manualTrigger);
            }
        }

        private void EmitState(AppStatus status, string portalUrl)
        {
            _onStateChanged(FormatPresentation(status, _authCount, portalUrl));
        }

        private void EmitNotify(string key, string title, string text, ToolTipIcon icon, bool force)
        {
            NotificationRequest req = new NotificationRequest();
            req.Key = key;
            req.Title = title;
            req.Text = text;
            req.Icon = icon;
            req.Force = force;
            _onNotify(req);
        }

        private static bool WaitForDefaultRoute(int maxMs)
        {
            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < maxMs)
            {
                if (ObitPortalClient.FastPathDefaultOnline()) return true;
                Thread.Sleep(750);
            }
            return false;
        }
    }
}
