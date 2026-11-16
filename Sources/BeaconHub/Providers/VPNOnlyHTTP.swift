import Foundation
import Network

enum VPNOnlyError: LocalizedError {
    case noVPN, notThroughProxy, timeout, badResponse

    var errorDescription: String? {
        switch self {
        case .noVPN: return "Нет VPN: запрос к Claude не отправлен. Как только VPN подключится, лимиты обновятся."
        case .notThroughProxy: return "Запрос пошёл мимо прокси VPN, опрос Claude остановлен. Проверь настройки VPN."
        case .timeout: return "VPN не ответил вовремя, повторю позже."
        case .badResponse: return "Не удалось прочитать ответ Claude API."
        }
    }
}

/// HTTPS-запрос, который физически не может уйти мимо VPN.
///
/// Как это работает, в общем виде, для любого VPN-клиента (Happ, WireGuard, Outline, IKEv2…):
/// - **VPN-туннель** (Network Extension или TUN, интерфейсы `utun*`, `ipsec*`, `ppp*`, `tun*`, `wg*`).
///   1. Перед запросом у ядра спрашивается маршрут именно до этого хоста (с учётом раздельного туннелирования).
///      Если он идёт не через туннель, соединение даже не открывается.
///   2. Когда соединение установлено, но **до отправки HTTP-запроса с токеном**, проверяется локальный адрес сокета.
///      Если это не адрес туннеля (VPN отвалился в последний момент или IPv6 ушёл мимо туннеля), соединение
///      закрывается, и токен аккаунта не уходит. Привязать сокет к туннелю напрямую нельзя: Network.framework
///      не видит TUN-интерфейсы VPN-клиентов.
/// - **Системный прокси** (режим «системный прокси» у VPN-клиентов). Запрос идёт через URLSession, который
///   использует прокси, а после ответа проверяется, что соединение действительно шло через прокси.
///   Если нет, опрос останавливается.
enum VPNOnlyHTTP {
    struct Response {
        let status: Int
        let body: Data
    }

    static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]

    /// Интерфейс, через который ядро отправит пакеты к хосту (IPv4), и его адрес, если это туннель.
    static func tunnelRoute(to host: String) async -> (interface: String, address: String)? {
        guard let r = try? await Shell.run("/sbin/route", ["-n", "get", "-inet", host], timeout: 5), r.status == 0,
              let line = r.stdoutString.split(separator: "\n").first(where: { $0.contains("interface:") }) else { return nil }
        let name = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard tunnelPrefixes.contains(where: name.hasPrefix), let address = ipv4Address(of: name) else { return nil }
        return (name, address)
    }

    /// Все адреса туннельных интерфейсов (IPv4 и IPv6).
    static func tunnelAddresses() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            guard tunnelPrefixes.contains(where: name.hasPrefix), let addr = ifa.ifa_addr,
                  [UInt8(AF_INET), UInt8(AF_INET6)].contains(addr.pointee.sa_family) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.insert(String(cString: host).split(separator: "%").first.map(String.init) ?? "")
            }
        }
        return result
    }

    static func ipv4Address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(cString: ifa.ifa_name) == interface, let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    static func get(_ url: URL, headers: [String: String], timeout: TimeInterval = 20) async throws -> Response {
        // Туннель проверяем первым: в TUN-режиме VPN-клиенты часто ещё и включают системный прокси.
        if let host = url.host, await tunnelRoute(to: host) != nil {
            return try await viaTunnel(url, headers: headers, timeout: timeout)
        }
        if systemProxyEnabled() {
            return try await viaProxy(url, headers: headers, timeout: timeout)
        }
        throw VPNOnlyError.noVPN
    }

    // MARK: Системный прокси

    /// Включён ли в системе HTTPS- или SOCKS-прокси (так работают VPN-клиенты в режиме «системный прокси»).
    static func systemProxyEnabled() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        let https = (settings[kCFNetworkProxiesHTTPSEnable as String] as? Int ?? 0) == 1
        let socks = (settings["SOCKSEnable"] as? Int ?? 0) == 1
        return https || socks
    }

    /// Хост в исключениях прокси: такой запрос пойдёт напрямую.
    static func proxyExcludes(_ host: String) -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let list = settings[kCFNetworkProxiesExceptionsList as String] as? [String] else { return false }
        return list.contains { pattern in
            let p = pattern.lowercased().replacingOccurrences(of: "*.", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "*."))
            return !p.isEmpty && (host == p || host.hasSuffix("." + p))
        }
    }

    private static func viaProxy(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> Response {
        if let host = url.host, proxyExcludes(host) {
            // Хост в исключениях прокси: остаётся только туннель, если он есть.
            return try await viaTunnel(url, headers: headers, timeout: timeout)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let delegate = MetricsDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: req)
        // Ответ уже получен, но, если соединение шло напрямую, дальше не опрашиваем.
        if delegate.wentDirect { throw VPNOnlyError.notThroughProxy }
        return Response(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private(set) var wentDirect = false
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            // Только реальные сетевые соединения (из кеша ничего не уходит).
            let network = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }
            if network.contains(where: { !$0.isProxyConnection }) { wentDirect = true }
        }
    }

    // MARK: Туннель

    private static func viaTunnel(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> Response {
        guard let host = url.host else { throw VPNOnlyError.badResponse }
        guard await tunnelRoute(to: host) != nil else { throw VPNOnlyError.noVPN }
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        params.preferNoProxies = true
        // Только IPv4: маршрут проверен для IPv4, а многие VPN не туннелируют IPv6.
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(url.port ?? 443)),
                                      using: params)

        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        var request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nAccept-Encoding: identity\r\n"
        for (k, v) in headers { request += "\(k): \(v)\r\n" }
        request += "\r\n"
        let payload = Data(request.utf8)

        let raw: Data = try await withCheckedThrowingContinuation { cont in
            let box = OnceBox(cont)
            var buffer = Data()
            let queue = DispatchQueue(label: "beaconhub.vpnonly")

            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
                    if let data { buffer.append(data) }
                    if done || Self.isComplete(buffer) {
                        connection.cancel()
                        box.resume(.success(buffer))
                    } else if let error {
                        connection.cancel()
                        box.resume(.failure(error))
                    } else {
                        receive()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Последний рубеж: соединение должно идти с адреса туннеля, иначе токен не отправляем.
                    guard case .hostPort(let local, _)? = connection.currentPath?.localEndpoint,
                          Self.tunnelAddresses().contains(Self.hostString(local)) else {
                        connection.cancel()
                        box.resume(.failure(VPNOnlyError.noVPN))
                        return
                    }
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error { connection.cancel(); box.resume(.failure(error)) } else { receive() }
                    })
                case .waiting:
                    // Сети нет совсем: ждать не будем.
                    connection.cancel()
                    box.resume(.failure(VPNOnlyError.noVPN))
                case .failed(let error):
                    box.resume(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                box.resume(.failure(VPNOnlyError.timeout))
            }
        }
        return try parse(raw)
    }

    static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)".split(separator: "%").first.map(String.init) ?? ""
        case .name(let n, _): return n
        @unknown default: return ""
        }
    }

    /// Ответ полностью получен (по Content-Length или по завершающему чанку).
    private static func isComplete(_ data: Data) -> Bool {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).lowercased()
        let bodyCount = data.count - split.upperBound
        if let line = head.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
           let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) {
            return bodyCount >= length
        }
        if head.contains("transfer-encoding: chunked") {
            return data.suffix(5) == Data("0\r\n\r\n".utf8)
        }
        return false
    }

    static func parse(_ raw: Data) throws -> Response {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { throw VPNOnlyError.badResponse }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { throw VPNOnlyError.badResponse }
        var body = Data(raw[split.upperBound...])
        if lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }) {
            body = dechunk(body)
        }
        return Response(status: status, body: body)
    }

    private static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while i < data.endIndex, let lineEnd = data.range(of: crlf, in: i..<data.endIndex) {
            let sizeLine = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }

    /// Continuation, который можно завершить только один раз (готовность, ошибка и таймаут могут прийти вместе).
    private final class OnceBox: @unchecked Sendable {
        private var cont: CheckedContinuation<Data, Error>?
        private let lock = NSLock()
        init(_ cont: CheckedContinuation<Data, Error>) { self.cont = cont }
        func resume(_ result: Result<Data, Error>) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(with: result)
        }
    }
}
