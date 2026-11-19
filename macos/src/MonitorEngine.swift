import Foundation

enum IconColor {
    case gray
    case green
    case orange
    case red
}

enum AppStatus {
    case checking
    case online
    case wifiDisconnected
    case vpnStalled
    case manualRequired
    case unknownPortal
    case offline
    case error
}

struct UiPresentation {
    let iconColor: IconColor
    let statusText: String
    let portalUrl: String
    let showPortalAction: Bool
}

struct NotificationRequest {
    let key: String
    let title: String
    let text: String
    let force: Bool
}

final class Logger {
    let logPath: String
    private let lock = NSLock()
    private let formatter: DateFormatter

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logDir = home.appendingPathComponent("Library/Logs/ObitAutoAuth", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        self.logPath = logDir.appendingPathComponent("obit-auth.log").path

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.formatter = df
    }

    func info(_ message: String) { write("INFO", message) }
    func warn(_ message: String) { write("WARN", message) }
    func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 512 * 1024 {
            let oldPath = logPath + ".old"
            try? fm.removeItem(atPath: oldPath)
            try? fm.moveItem(atPath: logPath, toPath: oldPath)
        }

        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if fm.fileExists(atPath: logPath), let handle = FileHandle(forWritingAtPath: logPath) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            fm.createFile(atPath: logPath, contents: data)
        }
    }
}

final class AppSettings {
    private enum Keys {
        static let notificationsEnabled = "notificationsEnabled"
        static let welcomeShown = "welcomeShown"
    }

    private let defaults = UserDefaults.standard

    var notificationsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.notificationsEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.notificationsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.notificationsEnabled)
        }
    }

    var welcomeShown: Bool {
        get { defaults.bool(forKey: Keys.welcomeShown) }
        set { defaults.set(newValue, forKey: Keys.welcomeShown) }
    }
}

final class MonitorEngine {
    private let log: Logger
    private let onStateChanged: (UiPresentation) -> Void
    private let onNotify: (NotificationRequest) -> Void

    private var authCount: Int = 0
    private var failStreak: Int = 0

    init(
        log: Logger,
        onStateChanged: @escaping (UiPresentation) -> Void,
        onNotify: @escaping (NotificationRequest) -> Void
    ) {
        self.log = log
        self.onStateChanged = onStateChanged
        self.onNotify = onNotify
    }

    static func formatPresentation(status: AppStatus, authCount: Int, portalUrl: String) -> UiPresentation {
        switch status {
        case .checking:
            return UiPresentation(
                iconColor: .gray,
                statusText: "Проверка входа...",
                portalUrl: "",
                showPortalAction: false
            )
        case .online:
            let text = authCount <= 0 ? "Авторизация активна" : "Авторизация активна (входов: \(authCount))"
            return UiPresentation(
                iconColor: .green,
                statusText: text,
                portalUrl: "",
                showPortalAction: false
            )
        case .wifiDisconnected:
            return UiPresentation(
                iconColor: .gray,
                statusText: "Wi-Fi не подключён",
                portalUrl: "",
                showPortalAction: false
            )
        case .vpnStalled:
            return UiPresentation(
                iconColor: .orange,
                statusText: "Вход есть, проверьте сеть или VPN",
                portalUrl: "",
                showPortalAction: false
            )
        case .manualRequired:
            return UiPresentation(
                iconColor: .red,
                statusText: "Нужен вход вручную (телефон/SMS)",
                portalUrl: portalUrl,
                showPortalAction: !portalUrl.isEmpty
            )
        case .unknownPortal:
            return UiPresentation(
                iconColor: .orange,
                statusText: "Нужен вход в эту сеть Wi-Fi",
                portalUrl: portalUrl,
                showPortalAction: !portalUrl.isEmpty
            )
        case .offline:
            return UiPresentation(
                iconColor: .orange,
                statusText: "Нет связи с сетью",
                portalUrl: "",
                showPortalAction: false
            )
        case .error:
            return UiPresentation(
                iconColor: .orange,
                statusText: "Ошибка авторизации",
                portalUrl: "",
                showPortalAction: false
            )
        }
    }

    func runCheckCycle(forceBypass: Bool, manualTrigger: Bool) {
        if manualTrigger {
            emitState(.checking, portalUrl: "")
        }

        if !forceBypass && ObitPortalClient.fastPathDefaultOnline() {
            if failStreak > 0 {
                log.info("Connectivity restored (failStreak was \(failStreak))")
            }
            failStreak = 0
            emitState(.online, portalUrl: "")
            if manualTrigger {
                emitNotify(
                    key: "online",
                    title: "Авторизация активна",
                    text: "Повторный вход не требуется.",
                    force: true
                )
            }
            return
        }

        guard let wifi = WifiAdapterInfo.detectActive() else {
            failStreak = 0
            emitState(.wifiDisconnected, portalUrl: "")
            if manualTrigger {
                emitNotify(
                    key: "wifi_off",
                    title: "Wi-Fi не подключён",
                    text: "Подключитесь к сети Wi-Fi и повторите проверку.",
                    force: true
                )
            }
            return
        }

        failStreak += 1
        let start = Date()
        let res = ObitPortalClient.checkAndAuthorize(wifi: wifi)
        let elapsed = Date().timeIntervalSince(start)

        switch res.outcome {
        case .authSuccess:
            authCount += 1
            failStreak = 0
            let vpnOk = waitForDefaultRoute(maxMs: 4000)
            log.info(String(format: "Re-authorized via %@ in %.2fs (vpn_online=%@)", wifi.name, elapsed, vpnOk ? "true" : "false"))
            emitState(.online, portalUrl: "")
            let text = vpnOk
                ? String(format: "Повторный вход занял %.1f с.", elapsed)
                : String(format: "Вход занял %.1f с, но сеть или VPN пока не отвечают.", elapsed)
            emitNotify(
                key: "auth_ok",
                title: "Вход в ОБИТ выполнен",
                text: text,
                force: manualTrigger
            )

        case .alreadyOnline:
            if ObitPortalClient.fastPathDefaultOnline() {
                failStreak = 0
                emitState(.online, portalUrl: "")
                if manualTrigger {
                    emitNotify(
                        key: "online",
                        title: "Авторизация активна",
                        text: "Повторный вход не требуется.",
                        force: true
                    )
                }
                return
            }

            log.warn("Wi-Fi '\(wifi.name)' is online via bypass, but default route/VPN is stalled")
            emitState(.vpnStalled, portalUrl: "")
            if manualTrigger || failStreak >= 2 {
                emitNotify(
                    key: "vpn_stalled",
                    title: "Вход есть, но сеть не отвечает",
                    text: "Авторизация активна. Проверьте сеть или перезапустите VPN.",
                    force: manualTrigger
                )
            }

        case .manualRequired:
            log.warn("Manual verification required: \(res.portalUrl)")
            emitState(.manualRequired, portalUrl: res.portalUrl)
            emitNotify(
                key: "manual",
                title: "Нужен вход вручную (телефон/SMS)",
                text: "Нажмите на уведомление или выберите «Открыть страницу входа» в меню значка.",
                force: manualTrigger
            )

        case .unknownPortal:
            log.info("Unknown portal: \(res.portalUrl)")
            emitState(.unknownPortal, portalUrl: res.portalUrl)
            emitNotify(
                key: "unknown:\(res.portalUrl)",
                title: "Нужен вход в эту сеть Wi-Fi",
                text: "Нажмите на уведомление или выберите «Открыть страницу входа» в меню значка.",
                force: manualTrigger
            )

        case .offline, .error:
            log.warn("Bypass check failed (\(res.outcome)): \(res.message)")
            emitState(res.outcome == .offline ? .offline : .error, portalUrl: "")
            if manualTrigger || failStreak >= 2 {
                let isOffline = res.outcome == .offline
                emitNotify(
                    key: isOffline ? "offline" : "err",
                    title: isOffline ? "Нет связи с сетью" : "Ошибка авторизации",
                    text: isOffline
                        ? "Проверьте подключение к Wi-Fi или роутеру."
                        : "Не удалось выполнить вход. Подробности в журнале работы.",
                    force: manualTrigger
                )
            }
        }
    }

    private func emitState(_ status: AppStatus, portalUrl: String) {
        onStateChanged(MonitorEngine.formatPresentation(status: status, authCount: authCount, portalUrl: portalUrl))
    }

    private func emitNotify(key: String, title: String, text: String, force: Bool) {
        onNotify(NotificationRequest(key: key, title: title, text: text, force: force))
    }

    private func waitForDefaultRoute(maxMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(maxMs) / 1000.0)
        while Date() < deadline {
            if ObitPortalClient.fastPathDefaultOnline() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.75)
        }
        return false
    }
}
