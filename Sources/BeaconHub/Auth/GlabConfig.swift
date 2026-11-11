import Foundation

/// Хост из конфига glab CLI (`glab auth login`).
struct GlabHost: Equatable {
    var host: String
    var token: String?
    var apiHost: String?
    var apiProtocol: String?
    var user: String?
    var isOAuth2 = false
}

/// Читает конфиг glab: это позволяет подхватить авторизацию без лишних действий от пользователя.
enum GlabConfig {
    static var candidateURLs: [URL] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        if let dir = env["GLAB_CONFIG_DIR"] {
            urls.append(URL(fileURLWithPath: dir).appendingPathComponent("config.yml"))
        }
        urls.append(home.appendingPathComponent("Library/Application Support/glab-cli/config.yml"))
        let xdg = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        urls.append(xdg.appendingPathComponent("glab-cli/config.yml"))
        return urls
    }

    static func load() -> [GlabHost] {
        guard let url = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Минимальный разбор секции `hosts:`. Полноценный YAML-парсер здесь не нужен.
    static func parse(_ text: String) -> [GlabHost] {
        var hosts: [GlabHost] = []
        var inHosts = false
        var hostIndent: Int?
        var current: GlabHost?

        func flush() {
            if let c = current { hosts.append(c) }
            current = nil
        }

        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = raw.prefix(while: { $0 == " " }).count

            if indent == 0 {
                flush()
                inHosts = trimmed == "hosts:"
                hostIndent = nil
                continue
            }
            guard inHosts, let colon = trimmed.firstIndex(of: ":") else { continue }

            let key = unquote(String(trimmed[..<colon]))
            let value = unquote(String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces))

            if hostIndent == nil { hostIndent = indent }
            if indent == hostIndent {
                flush()
                current = GlabHost(host: key)
            } else if let h = hostIndent, indent > h, current != nil {
                let v = value.isEmpty ? nil : value
                switch key {
                case "token": current?.token = v
                case "api_host": current?.apiHost = v
                case "api_protocol": current?.apiProtocol = v
                case "user": current?.user = v
                case "is_oauth2": current?.isOAuth2 = value == "true"
                default: break
                }
            }
        }
        flush()
        return hosts
    }

    private static func unquote(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}

/// Обновление OAuth-токена через сам glab: любой его API-вызов освежает протухший токен в конфиге.
actor GlabRefresher {
    static let shared = GlabRefresher()
    private var inflight: [String: Task<Void, Never>] = [:]

    func refresh(host: String) async {
        if let task = inflight[host] {
            await task.value
            return
        }
        guard let glab = Shell.which("glab") else { return }
        let task = Task {
            Log.info("glab: обновляю токен для \(host)")
            _ = try? await Shell.run(glab, ["api", "--hostname", host, "user"])
        }
        inflight[host] = task
        await task.value
        inflight[host] = nil
    }
}
