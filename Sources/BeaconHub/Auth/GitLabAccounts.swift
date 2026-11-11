import Foundation

struct GitLabAccount: Identifiable, Hashable {
    enum Source: String { case glab, manual }

    var host: String
    var apiBase: URL
    var webBase: URL
    var token: String?
    var source: Source
    var user: String?

    var id: String { host }
}

/// Собирает аккаунты GitLab из двух источников: конфиг glab и токены, добавленные вручную (Keychain).
/// Ручной токен для того же хоста имеет приоритет.
enum GitLabAccounts {
    static let manualHostsKey = "manualHosts"

    static var manualHosts: [String] {
        UserDefaults.standard.stringArray(forKey: manualHostsKey) ?? []
    }

    static func all() -> [GitLabAccount] {
        var byHost: [String: GitLabAccount] = [:]
        var order: [String] = []

        for h in GlabConfig.load() {
            let proto = h.apiProtocol ?? "https"
            let apiHost = h.apiHost ?? h.host
            guard let api = URL(string: "\(proto)://\(apiHost)/api/v4/"),
                  let web = URL(string: "https://\(h.host)") else { continue }
            byHost[h.host] = GitLabAccount(host: h.host, apiBase: api, webBase: web,
                                           token: h.token, source: .glab, user: h.user)
            order.append(h.host)
        }

        for host in manualHosts {
            guard let api = URL(string: "https://\(host)/api/v4/"),
                  let web = URL(string: "https://\(host)") else { continue }
            let user = byHost[host]?.user
            byHost[host] = GitLabAccount(host: host, apiBase: api, webBase: web,
                                         token: Keychain.get(host), source: .manual, user: user)
            if !order.contains(host) { order.append(host) }
        }
        return order.compactMap { byHost[$0] }
    }

    static func account(for host: String) -> GitLabAccount? {
        all().first { $0.host == host }
    }

    static func addManual(host: String, token: String) {
        Keychain.set(token, for: host)
        var hosts = manualHosts
        if !hosts.contains(host) { hosts.append(host) }
        UserDefaults.standard.set(hosts, forKey: manualHostsKey)
    }

    static func removeManual(host: String) {
        Keychain.delete(host)
        UserDefaults.standard.set(manualHosts.filter { $0 != host }, forKey: manualHostsKey)
    }

    /// Нормализует ввод пользователя («https://gitlab.example.com/», «gitlab.example.com») в хост.
    static func normalizeHost(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s), let host = comps.host, !host.isEmpty else { return nil }
        if let port = comps.port { return "\(host):\(port)" }
        return host
    }
}
