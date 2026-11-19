import Foundation

enum PortalOutcome {
    case alreadyOnline
    case authSuccess
    case manualRequired
    case unknownPortal
    case offline
    case error
}

final class PortalCheckResult {
    var outcome: PortalOutcome = .error
    var portalUrl: String = ""
    var message: String = ""
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum ObitPortalClient {
    static let probeUrl = "http://connectivitycheck.gstatic.com/generate_204"

    private static let metaRefreshRegex = try! NSRegularExpression(
        pattern: #"<meta[^>]+http-equiv=["']?refresh["']?[^>]+content=["']?\d+\s*;\s*url=([^"'>\s]+)"#,
        options: [.caseInsensitive]
    )
    private static let jsLocationRegex = try! NSRegularExpression(
        pattern: #"(?:window\.location(?:\.href)?|location\.replace)\s*(?:=|\()\s*["']([^"']+)["']"#,
        options: [.caseInsensitive]
    )
    private static let sessIdRegex = try! NSRegularExpression(
        pattern: #"OBIT_SessID=([a-zA-Z0-9_-]+)"#,
        options: []
    )
    private static let connectBtnRegex = try! NSRegularExpression(
        pattern: #"id=["']connect_btn["'][^>]*onclick=(?:"[^"]*?(confirm\.php\?[^"'\s]+)|'[^']*?(confirm\.php\?[^"'\s]+))"#,
        options: [.caseInsensitive]
    )
    private static let formBlockRegex = try! NSRegularExpression(
        pattern: #"<form\b[^>]*action=["']([^"']+)["'][^>]*>([\s\S]*?)(?:</form>|$)"#,
        options: [.caseInsensitive]
    )
    private static let formMethodRegex = try! NSRegularExpression(
        pattern: #"method=["']([^"']+)["']"#,
        options: [.caseInsensitive]
    )
    private static let inputTagRegex = try! NSRegularExpression(
        pattern: #"<input\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let inputNameRegex = try! NSRegularExpression(
        pattern: #"\bname=["']([^"']+)["']"#,
        options: [.caseInsensitive]
    )
    private static let inputValueRegex = try! NSRegularExpression(
        pattern: #"\bvalue=["']([^"']*)["']"#,
        options: [.caseInsensitive]
    )

    static func fastPathDefaultOnline() -> Bool {
        guard let url = URL(string: probeUrl) else { return false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 2.5
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.connectionProxyDictionary = [:]

        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let sem = DispatchSemaphore(value: 0)
        var is204 = false

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 2.5)
        req.httpMethod = "GET"

        let task = session.dataTask(with: req) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 204 {
                is204 = true
            }
            sem.signal()
        }
        task.resume()

        if sem.wait(timeout: .now() + 3.0) == .timedOut {
            task.cancel()
            return false
        }
        return is204
    }

    static func checkAndAuthorize(wifi: WifiAdapterInfo) -> PortalCheckResult {
        let result = PortalCheckResult()
        let client = BypassHttpClient(wifi: wifi)

        do {
            var probe = try client.request(url: probeUrl, method: "GET", followRedirects: true, timeoutMs: 5000)
            probe = try followHtmlRedirects(client: client, initial: probe)
            if probe.statusCode == 204 {
                result.outcome = .alreadyOnline
                result.message = "Wi-Fi online"
                return result
            }

            let portalUrl = probe.finalUrl
            let body = probe.body
            result.portalUrl = portalUrl

            let isObit = portalUrl.range(of: "obit.ru", options: .caseInsensitive) != nil ||
                portalUrl.contains("OBIT_SessID") ||
                body.contains("OBIT_SessID")

            if !isObit {
                result.outcome = .unknownPortal
                result.message = "Неизвестный captive-портал: \(portalUrl)"
                return result
            }

            guard let btnGroups = firstMatchGroups(connectBtnRegex, in: body) else {
                if body.range(of: "id=\"call_btn\"", options: .caseInsensitive) != nil ||
                    body.range(of: "stage=stage2", options: .caseInsensitive) != nil ||
                    body.range(of: "type=\"tel\"", options: .caseInsensitive) != nil {
                    result.outcome = .manualRequired
                    result.message = "Портал ОБИТ требует подтверждение по телефону/SMS."
                    return result
                }
                result.outcome = .error
                result.message = "Не найдена кнопка Подключиться на странице портала."
                return result
            }

            guard let sessGroups = firstMatchGroups(sessIdRegex, in: portalUrl) ?? firstMatchGroups(sessIdRegex, in: body),
                  let sessId = sessGroups[1] else {
                result.outcome = .error
                result.message = "Не найден OBIT_SessID."
                return result
            }

            let rawRel = btnGroups[1] ?? btnGroups[2] ?? ""
            let stage3Rel = decodeHtmlEntities(rawRel)

            guard let portalUri = URL(string: portalUrl),
                  let ajxUrl = URL(
                    string: "confirm.php?stage=ajx_check&OBIT_SessID=\(sessId)&width=1920&height=1080",
                    relativeTo: portalUri
                  )?.absoluteURL.absoluteString,
                  let stage3Url = URL(string: stage3Rel, relativeTo: portalUri)?.absoluteURL.absoluteString else {
                result.outcome = .error
                result.message = "Некорректный URL портала ОБИТ."
                return result
            }

            _ = try client.request(
                url: ajxUrl,
                method: "GET",
                referer: portalUrl,
                followRedirects: true,
                timeoutMs: 5000,
                isAjax: true
            )
            var st3 = try client.request(
                url: stage3Url,
                method: "GET",
                referer: portalUrl,
                followRedirects: true,
                timeoutMs: 5000
            )
            st3 = try followHtmlRedirects(client: client, initial: st3)

            if st3.statusCode != 204 {
                try submitAutoFormIfPresent(client: client, st3: st3)
            }

            let verify = try client.request(url: probeUrl, method: "GET", followRedirects: true, timeoutMs: 5000)
            if verify.statusCode == 204 {
                result.outcome = .authSuccess
                result.message = "Авторизация в ОБИТ успешно выполнена."
                return result
            }

            result.outcome = .error
            result.message = "После stage3 проверка вернула HTTP \(verify.statusCode)"
            return result
        } catch let err as NetworkBypassError {
            switch err {
            case .timeout, .dnsFailed, .networkError:
                result.outcome = .offline
            default:
                result.outcome = .error
            }
            result.message = err.localizedDescription
            return result
        } catch {
            result.outcome = .error
            result.message = error.localizedDescription
            return result
        }
    }

    private static func followHtmlRedirects(client: BypassHttpClient, initial: HttpResponseData) throws -> HttpResponseData {
        var resp = initial
        for _ in 0..<5 {
            if resp.statusCode == 204 { return resp }
            var nextTarget: String?

            if let meta = firstMatchGroups(metaRefreshRegex, in: resp.body), let raw = meta[1] {
                nextTarget = decodeHtmlEntities(raw)
            } else if resp.finalUrl.range(of: "confirm.php", options: .caseInsensitive) == nil,
                      let js = firstMatchGroups(jsLocationRegex, in: resp.body), let raw = js[1] {
                nextTarget = decodeHtmlEntities(raw)
            }

            guard let target = nextTarget, !target.isEmpty,
                  let base = URL(string: resp.finalUrl),
                  let nextUrl = URL(string: target, relativeTo: base)?.absoluteURL.absoluteString,
                  nextUrl.caseInsensitiveCompare(resp.finalUrl) != .orderedSame else {
                break
            }

            resp = try client.request(
                url: nextUrl,
                method: "GET",
                referer: resp.finalUrl,
                followRedirects: true,
                timeoutMs: 5000
            )
        }
        return resp
    }

    private static func submitAutoFormIfPresent(client: BypassHttpClient, st3: HttpResponseData) throws {
        let nsBody = st3.body as NSString
        let range = NSRange(location: 0, length: nsBody.length)
        guard let formMatch = formBlockRegex.firstMatch(in: st3.body, options: [], range: range) else {
            return
        }

        let fullFormTag = nsBody.substring(with: formMatch.range)
        let actionRaw = nsBody.substring(with: formMatch.range(at: 1))
        let action = decodeHtmlEntities(actionRaw)
        guard !action.isEmpty,
              let base = URL(string: st3.finalUrl),
              let target = URL(string: action, relativeTo: base)?.absoluteURL.absoluteString else {
            return
        }

        let formMethod = firstMatchGroups(formMethodRegex, in: fullFormTag)?[1]?.uppercased() ?? "GET"
        let formInner = nsBody.substring(with: formMatch.range(at: 2))
        let nsInner = formInner as NSString
        let inputMatches = inputTagRegex.matches(
            in: formInner,
            options: [],
            range: NSRange(location: 0, length: nsInner.length)
        )

        var pairs: [String] = []
        for tagMatch in inputMatches {
            let tag = nsInner.substring(with: tagMatch.range)
            guard let name = firstMatchGroups(inputNameRegex, in: tag)?[1], !name.isEmpty else {
                continue
            }
            let rawVal = firstMatchGroups(inputValueRegex, in: tag)?[1] ?? ""
            let val = decodeHtmlEntities(rawVal)
            let encName = urlEncodeFormComponent(name)
            let encVal = urlEncodeFormComponent(val)
            pairs.append("\(encName)=\(encVal)")
        }

        let payload = pairs.joined(separator: "&")
        if formMethod == "POST" {
            _ = try client.request(
                url: target,
                method: "POST",
                bodyData: payload,
                referer: st3.finalUrl,
                followRedirects: true,
                timeoutMs: 5000
            )
        } else if !payload.isEmpty {
            let sep = target.contains("?") ? "&" : "?"
            _ = try client.request(
                url: target + sep + payload,
                method: "GET",
                referer: st3.finalUrl,
                followRedirects: true,
                timeoutMs: 5000
            )
        } else {
            _ = try client.request(
                url: target,
                method: "GET",
                referer: st3.finalUrl,
                followRedirects: true,
                timeoutMs: 5000
            )
        }
    }

    private static func urlEncodeFormComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func decodeHtmlEntities(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
    }

    private static func firstMatchGroups(_ regex: NSRegularExpression, in text: String) -> [Int: String]? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [Int: String] = [:]
        for idx in 0..<match.numberOfRanges {
            let r = match.range(at: idx)
            if r.location != NSNotFound {
                groups[idx] = ns.substring(with: r)
            }
        }
        return groups
    }
}
