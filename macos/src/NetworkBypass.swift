import Darwin
import Foundation
import Network
import Security
import SystemConfiguration

enum NetworkBypassError: Error, LocalizedError {
    case timeout(String)
    case dnsFailed(String)
    case networkError(String)
    case malformedResponse(String)
    case tooManyRedirects

    var errorDescription: String? {
        switch self {
        case .timeout(let msg): return msg
        case .dnsFailed(let msg): return msg
        case .networkError(let msg): return msg
        case .malformedResponse(let msg): return msg
        case .tooManyRedirects: return "Too many HTTP redirects"
        }
    }
}

final class WifiAdapterInfo {
    let name: String
    let nwInterface: NWInterface
    let localIp: String
    let gatewayIp: String
    let dnsServers: [String]

    init(
        name: String,
        nwInterface: NWInterface,
        localIp: String,
        gatewayIp: String,
        dnsServers: [String]
    ) {
        self.name = name
        self.nwInterface = nwInterface
        self.localIp = localIp
        self.gatewayIp = gatewayIp
        self.dnsServers = dnsServers
    }

    static func detectActive() -> WifiAdapterInfo? {
        guard let wifiIface = findActiveWifiInterface() else {
            return nil
        }

        let ifaceName = wifiIface.name
        guard let store = SCDynamicStoreCreate(nil, "ObitAutoAuth" as CFString, nil, nil) else {
            return nil
        }

        var localIp: String?
        var gatewayIp: String?
        var dnsServers: [String] = []

        if let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] {
            for key in keys {
                guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      let boundName = dict["InterfaceName"] as? String,
                      boundName == ifaceName else {
                    continue
                }

                if let addrs = dict["Addresses"] as? [String] {
                    localIp = addrs.first(where: { isUsableIPv4($0) })
                }
                if let router = dict["Router"] as? String, isUsableIPv4(router) {
                    gatewayIp = router
                }

                let serviceDnsKey = key.replacingOccurrences(of: "/IPv4", with: "/DNS")
                if let dnsDict = SCDynamicStoreCopyValue(store, serviceDnsKey as CFString) as? [String: Any],
                   let servers = dnsDict["ServerAddresses"] as? [String] {
                    dnsServers = servers.filter { isUsableIPv4($0) }
                }
                break
            }
        }

        if localIp == nil {
            let ifaceKey = "State:/Network/Interface/\(ifaceName)/IPv4" as CFString
            if let dict = SCDynamicStoreCopyValue(store, ifaceKey) as? [String: Any] {
                if let addrs = dict["Addresses"] as? [String] {
                    localIp = addrs.first(where: { isUsableIPv4($0) })
                }
                if gatewayIp == nil, let router = dict["Router"] as? String, isUsableIPv4(router) {
                    gatewayIp = router
                }
            }
        }

        guard let ip = localIp, let gw = gatewayIp else {
            return nil
        }

        if dnsServers.isEmpty {
            dnsServers = [gw]
        }

        return WifiAdapterInfo(
            name: ifaceName,
            nwInterface: wifiIface,
            localIp: ip,
            gatewayIp: gw,
            dnsServers: dnsServers
        )
    }

    private static func findActiveWifiInterface() -> NWInterface? {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let queue = DispatchQueue(label: "ru.obit.autoauth.wifi-detect")
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var signaled = false
        var detected: NWInterface?

        monitor.pathUpdateHandler = { path in
            lock.lock()
            defer { lock.unlock() }
            if signaled { return }
            if path.status == .satisfied {
                detected = path.availableInterfaces.first(where: { $0.type == .wifi })
            }
            signaled = true
            sem.signal()
        }

        monitor.start(queue: queue)
        _ = sem.wait(timeout: .now() + 1.5)
        monitor.cancel()
        return detected
    }

    private static func isUsableIPv4(_ value: String) -> Bool {
        if value.isEmpty || value == "0.0.0.0" || value.hasPrefix("127.") {
            return false
        }
        var addr = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }
}

final class HttpResponseData {
    var statusCode: Int = 0
    var finalUrl: String = ""
    var body: String = ""
    var headers: [String: String] = [:]
}

final class BypassHttpClient {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let seqLock = NSLock()
    private static var dnsSeq: UInt16 = UInt16(truncatingIfNeeded: ProcessInfo.processInfo.processIdentifier)

    private let wifi: WifiAdapterInfo
    private let queue = DispatchQueue(label: "ru.obit.autoauth.bypass-io")
    private var dnsCache: [String: String] = [:]
    private var cookies: [String: String] = [:]

    init(wifi: WifiAdapterInfo) {
        self.wifi = wifi
    }

    func request(
        url: String,
        method: String = "GET",
        bodyData: String? = nil,
        referer: String? = nil,
        followRedirects: Bool = true,
        timeoutMs: Int = 5000,
        isAjax: Bool = false
    ) throws -> HttpResponseData {
        var currentUrl = url
        var currentMethod = method
        var currentBody = bodyData
        var currentReferer = referer
        var currentAjax = isAjax

        for _ in 0..<8 {
            let resp = try sendSingle(
                url: currentUrl,
                method: currentMethod,
                bodyData: currentBody,
                referer: currentReferer,
                timeoutMs: timeoutMs,
                isAjax: currentAjax
            )

            if followRedirects && [301, 302, 303, 307, 308].contains(resp.statusCode),
               let loc = headerValue(resp.headers, "Location"), !loc.isEmpty,
               let base = URL(string: currentUrl),
               let nextUrl = URL(string: loc, relativeTo: base)?.absoluteURL {
                currentReferer = currentUrl
                currentUrl = nextUrl.absoluteString
                if resp.statusCode == 303 || ((resp.statusCode == 301 || resp.statusCode == 302) && currentMethod == "POST") {
                    currentMethod = "GET"
                    currentBody = nil
                }
                currentAjax = false
                continue
            }

            return resp
        }

        throw NetworkBypassError.tooManyRedirects
    }

    private func resolveHost(_ host: String, timeoutMs: Int) throws -> String {
        var addr = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 {
            return host
        }

        if let cached = dnsCache[host] {
            return cached
        }

        let (txId, queryData) = buildDnsAQuery(host: host)

        for dnsServer in wifi.dnsServers {
            if let resolved = try? sendUdpDnsQuery(queryData: queryData, txId: txId, dnsServer: dnsServer, timeoutMs: timeoutMs) {
                dnsCache[host] = resolved
                return resolved
            }
        }

        throw NetworkBypassError.dnsFailed("DNS resolution failed via Wi-Fi DNS for \(host)")
    }

    private func sendUdpDnsQuery(queryData: Data, txId: UInt16, dnsServer: String, timeoutMs: Int) throws -> String? {
        let params = NWParameters.udp
        params.requiredInterface = wifi.nwInterface
        if let ipOpts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4
        }

        guard let port = NWEndpoint.Port(rawValue: 53) else {
            return nil
        }

        let conn = NWConnection(host: NWEndpoint.Host(dnsServer), port: port, using: params)
        defer { conn.cancel() }

        try waitForReady(conn, timeoutMs: timeoutMs, label: "DNS \(dnsServer)")

        let sendSem = DispatchSemaphore(value: 0)
        var sendErr: NWError?
        conn.send(content: queryData, completion: .contentProcessed { err in
            sendErr = err
            sendSem.signal()
        })
        if sendSem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            throw NetworkBypassError.timeout("DNS send timed out")
        }
        if let err = sendErr {
            throw NetworkBypassError.networkError(err.localizedDescription)
        }

        let recvSem = DispatchSemaphore(value: 0)
        var recvData: Data?
        conn.receiveMessage { data, _, _, _ in
            recvData = data
            recvSem.signal()
        }
        if recvSem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            throw NetworkBypassError.timeout("DNS receive timed out")
        }

        guard let packet = recvData else {
            return nil
        }
        return parseDnsAResponse(packet: packet, expectedTxId: txId)
    }

    private func buildDnsAQuery(host: String) -> (UInt16, Data) {
        BypassHttpClient.seqLock.lock()
        BypassHttpClient.dnsSeq &+= 1
        if BypassHttpClient.dnsSeq == 0 {
            BypassHttpClient.dnsSeq = 1
        }
        let txId = BypassHttpClient.dnsSeq
        BypassHttpClient.seqLock.unlock()

        var pkt = Data()
        pkt.append(UInt8(txId >> 8))
        pkt.append(UInt8(txId & 0xFF))
        pkt.append(contentsOf: [0x01, 0x00]) // Standard query, recursion desired
        pkt.append(contentsOf: [0x00, 0x01]) // QDCOUNT = 1
        pkt.append(contentsOf: [0x00, 0x00]) // ANCOUNT = 0
        pkt.append(contentsOf: [0x00, 0x00]) // NSCOUNT = 0
        pkt.append(contentsOf: [0x00, 0x00]) // ARCOUNT = 0

        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        for label in trimmed.split(separator: ".") {
            let bytes = Array(label.utf8)
            pkt.append(UInt8(bytes.count))
            pkt.append(contentsOf: bytes)
        }
        pkt.append(0x00)
        pkt.append(contentsOf: [0x00, 0x01]) // QTYPE = A
        pkt.append(contentsOf: [0x00, 0x01]) // QCLASS = IN
        return (txId, pkt)
    }

    private static func skipDnsName(bytes: [UInt8], offset start: Int) -> Int {
        var offset = start
        while offset < bytes.count {
            let b = bytes[offset]
            if b == 0 {
                return offset + 1
            }
            if (b & 0xC0) == 0xC0 {
                return offset + 2
            }
            offset += 1 + Int(b)
        }
        return bytes.count
    }

    private func parseDnsAResponse(packet: Data, expectedTxId: UInt16) -> String? {
        let bytes = [UInt8](packet)
        if bytes.count < 12 { return nil }

        let txId = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        if txId != expectedTxId { return nil }
        if (bytes[3] & 0x0F) != 0 { return nil }

        let qdCount = (Int(bytes[4]) << 8) | Int(bytes[5])
        let anCount = (Int(bytes[6]) << 8) | Int(bytes[7])
        var offset = 12

        for _ in 0..<qdCount {
            offset = BypassHttpClient.skipDnsName(bytes: bytes, offset: offset) + 4
        }

        for _ in 0..<anCount {
            if offset >= bytes.count { break }
            offset = BypassHttpClient.skipDnsName(bytes: bytes, offset: offset)
            if offset + 10 > bytes.count { break }
            let rtype = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            let rclass = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            let rdLen = (Int(bytes[offset + 8]) << 8) | Int(bytes[offset + 9])
            offset += 10
            if rtype == 1 && rclass == 1 && rdLen == 4 && offset + 4 <= bytes.count {
                return "\(bytes[offset]).\(bytes[offset + 1]).\(bytes[offset + 2]).\(bytes[offset + 3])"
            }
            offset += rdLen
        }
        return nil
    }

    private func sendSingle(
        url: String,
        method: String,
        bodyData: String?,
        referer: String?,
        timeoutMs: Int,
        isAjax: Bool
    ) throws -> HttpResponseData {
        guard let uri = URL(string: url), let host = uri.host else {
            throw NetworkBypassError.malformedResponse("Invalid URL: \(url)")
        }

        let isHttps = uri.scheme?.lowercased() == "https"
        let portNum = uri.port ?? (isHttps ? 443 : 80)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(portNum)) else {
            throw NetworkBypassError.malformedResponse("Invalid port: \(portNum)")
        }

        let targetIp = try resolveHost(host, timeoutMs: timeoutMs)

        let params: NWParameters
        if isHttps {
            let tlsOpts = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tlsOpts.securityProtocolOptions, host)
            params = NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
        } else {
            params = NWParameters.tcp
        }
        params.requiredInterface = wifi.nwInterface
        if let ipOpts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4
        }

        let conn = NWConnection(host: NWEndpoint.Host(targetIp), port: nwPort, using: params)
        defer { conn.cancel() }

        try waitForReady(conn, timeoutMs: timeoutMs, label: host)

        var pathAndQuery = uri.path.isEmpty ? "/" : uri.path
        if let q = uri.query, !q.isEmpty {
            pathAndQuery += "?\(q)"
        }
        let hostHeader = uri.port != nil ? "\(host):\(portNum)" : host

        var req = "\(method) \(pathAndQuery) HTTP/1.1\r\n"
        req += "Host: \(hostHeader)\r\n"
        req += "User-Agent: \(BypassHttpClient.userAgent)\r\n"
        req += "Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n"
        req += "Connection: close\r\n"
        if let ref = referer, !ref.isEmpty {
            req += "Referer: \(ref)\r\n"
        }
        if isAjax {
            req += "X-Requested-With: XMLHttpRequest\r\n"
        }
        let cookieHeader = buildCookieHeader()
        if !cookieHeader.isEmpty {
            req += "Cookie: \(cookieHeader)\r\n"
        }

        var bodyBytes: Data?
        if let body = bodyData, !body.isEmpty {
            let encoded = Data(body.utf8)
            bodyBytes = encoded
            req += "Content-Type: application/x-www-form-urlencoded\r\n"
            req += "Content-Length: \(encoded.count)\r\n"
        }
        req += "\r\n"

        var outData = Data(req.utf8)
        if let b = bodyBytes {
            outData.append(b)
        }

        let sendSem = DispatchSemaphore(value: 0)
        var sendErr: NWError?
        conn.send(content: outData, completion: .contentProcessed { err in
            sendErr = err
            sendSem.signal()
        })
        if sendSem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            throw NetworkBypassError.timeout("HTTP send timed out: \(host)")
        }
        if let err = sendErr {
            throw NetworkBypassError.networkError(err.localizedDescription)
        }

        return try readHttpResponse(conn: conn, requestUrl: url, timeoutMs: timeoutMs)
    }

    private func waitForReady(_ conn: NWConnection, timeoutMs: Int, label: String) throws {
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var done = false
        var finalError: NWError?

        conn.stateUpdateHandler = { state in
            lock.lock()
            defer { lock.unlock() }
            if done { return }
            switch state {
            case .ready:
                done = true
                sem.signal()
            case .failed(let err):
                finalError = err
                done = true
                sem.signal()
            case .cancelled:
                finalError = NWError.posix(.ECANCELED)
                done = true
                sem.signal()
            default:
                break
            }
        }

        conn.start(queue: queue)
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            throw NetworkBypassError.timeout("Connect timed out: \(label)")
        }
        if let err = finalError {
            throw NetworkBypassError.networkError(err.localizedDescription)
        }
    }

    private func readChunk(_ conn: NWConnection, deadline: DispatchTime) throws -> (Data?, Bool) {
        let sem = DispatchSemaphore(value: 0)
        var chunk: Data?
        var isComplete = false
        var recvErr: NWError?

        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, err in
            chunk = data
            isComplete = complete
            recvErr = err
            sem.signal()
        }

        if sem.wait(timeout: deadline) == .timedOut {
            throw NetworkBypassError.timeout("HTTP receive timed out")
        }
        if let err = recvErr {
            throw NetworkBypassError.networkError(err.localizedDescription)
        }
        return (chunk, isComplete)
    }

    private func readHttpResponse(conn: NWConnection, requestUrl: String, timeoutMs: Int) throws -> HttpResponseData {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        var raw = Data()
        var headerEnd: Int?

        while headerEnd == nil {
            let (chunk, complete) = try readChunk(conn, deadline: deadline)
            if let data = chunk, !data.isEmpty {
                raw.append(data)
                headerEnd = findHeaderEnd(raw)
            }
            if complete || raw.count > 64 * 1024 {
                break
            }
        }

        guard let hdrEnd = headerEnd else {
            throw NetworkBypassError.malformedResponse("Malformed HTTP response from \(requestUrl)")
        }

        let headerData = raw.subdata(in: 0..<hdrEnd)
        let headerText = String(data: headerData, encoding: .ascii) ?? String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, !statusLine.isEmpty else {
            throw NetworkBypassError.malformedResponse("Empty HTTP status line")
        }

        let statusParts = statusLine.split(separator: " ")
        let statusCode = statusParts.count >= 2 ? (Int(statusParts[1]) ?? 0) : 0

        let response = HttpResponseData()
        response.statusCode = statusCode
        response.finalUrl = requestUrl

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                let pair = val.split(separator: ";", maxSplits: 1).first.map(String.init) ?? val
                if let eq = pair.firstIndex(of: "=") {
                    let cName = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
                    let cVal = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if !cName.isEmpty {
                        cookies[cName] = cVal
                    }
                }
            } else {
                response.headers[name] = val
            }
        }

        var bodyData = raw.count > hdrEnd + 4 ? raw.subdata(in: (hdrEnd + 4)..<raw.count) : Data()
        let contentLength = headerValue(response.headers, "Content-Length").flatMap { Int($0) } ?? -1
        let isChunked = headerValue(response.headers, "Transfer-Encoding")?.lowercased().contains("chunked") ?? false

        if statusCode != 204 && statusCode != 304 && contentLength != 0 {
            if isChunked, let decoded = tryDecodeChunked(bodyData) {
                response.body = String(data: decoded, encoding: .utf8) ?? String(decoding: decoded, as: UTF8.self)
                return response
            }

            while contentLength < 0 || bodyData.count < contentLength {
                let (chunk, complete) = try readChunk(conn, deadline: deadline)
                if let data = chunk, !data.isEmpty {
                    bodyData.append(data)
                    if isChunked, let decoded = tryDecodeChunked(bodyData) {
                        response.body = String(data: decoded, encoding: .utf8) ?? String(decoding: decoded, as: UTF8.self)
                        return response
                    }
                }
                if complete || bodyData.count > 512 * 1024 {
                    break
                }
            }
        }

        if isChunked {
            bodyData = tryDecodeChunked(bodyData, allowPartial: true) ?? bodyData
        }
        response.body = String(data: bodyData, encoding: .utf8) ?? String(decoding: bodyData, as: UTF8.self)
        return response
    }

    private func buildCookieHeader() -> String {
        if cookies.isEmpty { return "" }
        return cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func headerValue(_ headers: [String: String], _ key: String) -> String? {
        for (k, v) in headers {
            if k.caseInsensitiveCompare(key) == .orderedSame {
                return v
            }
        }
        return nil
    }

    private func findHeaderEnd(_ data: Data) -> Int? {
        let separator = Data([13, 10, 13, 10])
        return data.range(of: separator)?.lowerBound
    }

    private func tryDecodeChunked(_ input: Data, allowPartial: Bool = false) -> Data? {
        let bytes = [UInt8](input)
        var output = Data()
        var pos = 0

        while pos < bytes.count {
            var lineEnd = -1
            if pos + 2 <= bytes.count {
                for i in pos...(bytes.count - 2) {
                    if bytes[i] == 13 && bytes[i + 1] == 10 {
                        lineEnd = i
                        break
                    }
                }
            }
            if lineEnd < 0 {
                return allowPartial ? output : nil
            }

            let sizeData = Data(bytes[pos..<lineEnd])
            let sizeStr = (String(data: sizeData, encoding: .ascii) ?? "")
                .split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let chunkSize = Int(sizeStr, radix: 16), chunkSize >= 0 else {
                return allowPartial ? output : nil
            }
            if chunkSize == 0 {
                return (bytes.count >= lineEnd + 4 || allowPartial) ? output : nil
            }

            pos = lineEnd + 2
            if pos + chunkSize + 2 > bytes.count {
                if allowPartial {
                    let avail = max(0, bytes.count - pos)
                    output.append(contentsOf: bytes[pos..<(pos + min(chunkSize, avail))])
                    return output
                }
                return nil
            }
            output.append(contentsOf: bytes[pos..<(pos + chunkSize)])
            pos += chunkSize + 2
        }

        return allowPartial ? output : nil
    }
}
