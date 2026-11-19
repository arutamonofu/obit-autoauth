using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ObitAutoAuth
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            bool createdNew;
            using (Mutex mutex = new Mutex(true, "Local\\ObitAutoAuthSingleInstance", out createdNew))
            using (EventWaitHandle wakeEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\ObitAutoAuthWakeEvent"))
            {
                if (!createdNew)
                {
                    try { wakeEvent.Set(); } catch { }
                    return;
                }

                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayAppContext(wakeEvent));
            }
        }
    }

    internal sealed class TrayAppContext : ApplicationContext
    {
        private const string RunRegKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "ObitAutoAuth";

        private readonly string _appDir;
        private readonly Logger _log;
        private readonly AppSettings _settings;
        private readonly MonitorEngine _engine;
        private readonly NotifyIcon _trayIcon;
        private readonly ToolStripMenuItem _statusItem;
        private readonly ToolStripMenuItem _portalItem;
        private readonly ToolStripMenuItem _autostartItem;
        private readonly ToolStripMenuItem _notifyItem;
        private readonly Control _uiInvoker;
        private readonly System.Windows.Forms.Timer _timer;
        private readonly RegisteredWaitHandle _wakeWaitHandle;

        private int _checking = 0;
        private string _lastAlertKey = string.Empty;
        private DateTime _lastAlertUtc = DateTime.MinValue;
        private string _lastPortalUrl = string.Empty;
        private Icon _currentIcon;

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern bool DestroyIcon(IntPtr handle);

        public TrayAppContext(EventWaitHandle wakeEvent)
        {
            _appDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ObitAutoAuth");
            _log = new Logger(_appDir);
            _settings = new AppSettings(_appDir);
            _settings.Load();

            _engine = new MonitorEngine(_log, ApplyPresentation, HandleNotification);

            _statusItem = new ToolStripMenuItem("Проверка входа...");
            _statusItem.Enabled = false;

            _portalItem = new ToolStripMenuItem("Открыть страницу входа", null, OnOpenPortalClick);
            _portalItem.Visible = false;

            ToolStripMenuItem checkNowItem = new ToolStripMenuItem("Проверить и войти сейчас", null, OnCheckNowClick);
            _autostartItem = new ToolStripMenuItem("Запускать автоматически", null, OnToggleAutostart);
            _autostartItem.Checked = IsAutostartEnabled();

            _notifyItem = new ToolStripMenuItem("Показывать уведомления", null, OnToggleNotify);
            _notifyItem.Checked = _settings.NotificationsEnabled;

            ToolStripMenuItem openLogItem = new ToolStripMenuItem("Открыть журнал работы", null, OnOpenLog);
            ToolStripMenuItem exitItem = new ToolStripMenuItem("Выход", null, OnExit);

            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add(_statusItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(_portalItem);
            menu.Items.Add(checkNowItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(_autostartItem);
            menu.Items.Add(_notifyItem);
            menu.Items.Add(openLogItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exitItem);

            _trayIcon = new NotifyIcon();
            _trayIcon.ContextMenuStrip = menu;
            _trayIcon.Text = "OBIT Wi-Fi Auto-Auth";
            _trayIcon.Visible = true;
            _trayIcon.BalloonTipClicked += OnBalloonClicked;

            _uiInvoker = new Control();
            IntPtr invokerHandle = _uiInvoker.Handle;
            GC.KeepAlive(invokerHandle);

            ApplyPresentation(MonitorEngine.FormatPresentation(AppStatus.Checking, 0, string.Empty));

            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = 15000;
            _timer.Tick += OnTimerTick;
            _timer.Start();

            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            NetworkChange.NetworkAddressChanged += OnNetworkChanged;

            _wakeWaitHandle = ThreadPool.RegisterWaitForSingleObject(
                wakeEvent,
                OnSecondInstanceWake,
                null,
                -1,
                false);

            _log.Info("ObitAutoAuth started");
            if (!_settings.WelcomeShown)
            {
                _settings.WelcomeShown = true;
                _settings.Save();
                ShowBalloon("welcome", "OBIT Wi-Fi Auto-Auth запущен",
                    "Значок программы находится в области уведомлений возле часов.",
                    ToolTipIcon.Info, true);
            }

            TriggerCheckAsync(false, false);
        }

        private static bool IsAutostartEnabled()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunRegKey, false))
                {
                    return key != null && key.GetValue(RunValueName) != null;
                }
            }
            catch
            {
                return false;
            }
        }

        private void SetAutostart(bool enable)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunRegKey, true))
                {
                    if (key == null) return;
                    if (enable)
                    {
                        key.SetValue(RunValueName, "\"" + Application.ExecutablePath + "\"");
                    }
                    else
                    {
                        key.DeleteValue(RunValueName, false);
                    }
                }
            }
            catch (Exception ex)
            {
                _log.Warn("Autostart update failed: " + ex.Message);
            }
        }

        private void RunOnUi(Action action)
        {
            if (_uiInvoker != null && !_uiInvoker.IsDisposed && _uiInvoker.IsHandleCreated)
            {
                if (_uiInvoker.InvokeRequired)
                {
                    _uiInvoker.BeginInvoke(action);
                    return;
                }
            }
            action();
        }

        private void ApplyPresentation(UiPresentation p)
        {
            RunOnUi(delegate
            {
                _lastPortalUrl = p.ShowPortalAction ? p.PortalUrl : string.Empty;
                _portalItem.Visible = !string.IsNullOrEmpty(_lastPortalUrl);
                _statusItem.Text = p.StatusText;
                _trayIcon.Text = p.StatusText.Length > 63 ? p.StatusText.Substring(0, 63) : p.StatusText;
                UpdateTrayIcon(p.DotColor);
            });
        }

        private void UpdateTrayIcon(Color dotColor)
        {
            Size target = SystemInformation.SmallIconSize;
            int size = Math.Max(16, Math.Min(48, Math.Max(target.Width, target.Height)));
            float s = size / 16f;

            using (Bitmap bmp = new Bitmap(size, size))
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (SolidBrush outer = new SolidBrush(Color.FromArgb(40, 40, 40)))
                {
                    g.FillEllipse(outer, 0.8f * s, 0.8f * s, 14.4f * s, 14.4f * s);
                }
                using (SolidBrush inner = new SolidBrush(dotColor))
                {
                    g.FillEllipse(inner, 1.9f * s, 1.9f * s, 12.2f * s, 12.2f * s);
                }
                using (SolidBrush keyhole = new SolidBrush(Color.FromArgb(30, 30, 30)))
                {
                    g.FillEllipse(keyhole, 5.6f * s, 3.8f * s, 4.8f * s, 4.8f * s);
                    PointF[] stem = new PointF[]
                    {
                        new PointF(6.6f * s, 7.5f * s),
                        new PointF(9.4f * s, 7.5f * s),
                        new PointF(10.2f * s, 12.4f * s),
                        new PointF(5.8f * s, 12.4f * s),
                    };
                    g.FillPolygon(keyhole, stem);
                }
                IntPtr hIcon = bmp.GetHicon();
                Icon nextIcon = Icon.FromHandle(hIcon);
                Icon prevIcon = _currentIcon;
                _currentIcon = (Icon)nextIcon.Clone();
                _trayIcon.Icon = _currentIcon;
                nextIcon.Dispose();
                DestroyIcon(hIcon);
                if (prevIcon != null) prevIcon.Dispose();
            }
        }

        private void HandleNotification(NotificationRequest req)
        {
            ShowBalloon(req.Key, req.Title, req.Text, req.Icon, req.Force);
        }

        private void ShowBalloon(string key, string title, string text, ToolTipIcon icon, bool force)
        {
            if (!_settings.NotificationsEnabled && !force) return;
            DateTime now = DateTime.UtcNow;
            if (!force && key == _lastAlertKey && (now - _lastAlertUtc).TotalMinutes < 5)
            {
                return;
            }
            _lastAlertKey = key;
            _lastAlertUtc = now;
            RunOnUi(delegate
            {
                _trayIcon.ShowBalloonTip(5000, title, text, icon);
            });
        }

        private void OnTimerTick(object sender, EventArgs e) { TriggerCheckAsync(false, false); }
        private void OnCheckNowClick(object sender, EventArgs e) { TriggerCheckAsync(true, true); }
        private void OnNetworkChanged(object sender, EventArgs e) { TriggerCheckAsync(false, false); }

        private void OnSecondInstanceWake(object state, bool timedOut)
        {
            if (timedOut) return;
            ShowBalloon("already_running", "OBIT Wi-Fi Auto-Auth",
                "Программа уже запущена.", ToolTipIcon.Info, true);
            TriggerCheckAsync(true, false);
        }

        private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (e.Mode == PowerModes.Resume)
            {
                _log.Info("System resumed from sleep; scheduling check");
                ThreadPool.QueueUserWorkItem(delegate
                {
                    Thread.Sleep(3000);
                    TriggerCheckAsync(false, false);
                });
            }
        }

        private void TriggerCheckAsync(bool forceBypass, bool manualTrigger)
        {
            if (Interlocked.CompareExchange(ref _checking, 1, 0) != 0) return;

            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    _engine.RunCheckCycle(forceBypass, manualTrigger);
                }
                catch (Exception ex)
                {
                    _log.Error("Unhandled check error: " + ex.Message);
                }
                finally
                {
                    Interlocked.Exchange(ref _checking, 0);
                }
            });
        }

        private void OpenPortalUrl()
        {
            if (string.IsNullOrEmpty(_lastPortalUrl)) return;
            if (!_lastPortalUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
                !_lastPortalUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(_lastPortalUrl);
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch { }
        }

        private void OnOpenPortalClick(object sender, EventArgs e) { OpenPortalUrl(); }
        private void OnBalloonClicked(object sender, EventArgs e) { OpenPortalUrl(); }

        private void OnToggleAutostart(object sender, EventArgs e)
        {
            bool next = !_autostartItem.Checked;
            SetAutostart(next);
            _autostartItem.Checked = IsAutostartEnabled();
        }

        private void OnToggleNotify(object sender, EventArgs e)
        {
            _settings.NotificationsEnabled = !_notifyItem.Checked;
            _notifyItem.Checked = _settings.NotificationsEnabled;
            _settings.Save();
        }

        private void OnOpenLog(object sender, EventArgs e)
        {
            try
            {
                if (!File.Exists(_log.LogPath)) _log.Info("Log opened");
                Process.Start("notepad.exe", "\"" + _log.LogPath + "\"");
            }
            catch { }
        }

        private void OnExit(object sender, EventArgs e)
        {
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
            _wakeWaitHandle.Unregister(null);
            _timer.Stop();
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            if (_uiInvoker != null && !_uiInvoker.IsDisposed) _uiInvoker.Dispose();
            if (_currentIcon != null) _currentIcon.Dispose();
            _log.Info("ObitAutoAuth exited");
            Application.Exit();
        }
    }
}
