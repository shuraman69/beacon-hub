import Foundation

enum ClaudeError: LocalizedError {
    case notLoggedIn, expired, rateLimited, http(Int), badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Claude Code не найден. Установи его и войди в аккаунт (команда claude)."
        case .expired: return "Сессия Claude Code истекла. Запусти claude, он обновит токен."
        case .rateLimited: return "Слишком частые запросы, повторю позже."
        case .http(let code): return "Claude API ответил \(code)."
        case .badResponse: return "Не удалось разобрать ответ Claude API: возможно, формат поменялся."
        }
    }
}

/// Лимиты подписки Claude (5-часовое окно, неделя, недельные лимиты по моделям).
///
/// ⚠️ Эндпоинт неофициальный: его использует Claude Code для `/usage`. Если формат поменяется,
/// правка нужна только здесь, в `parse`.
enum ClaudeUsageProvider {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static var requireVPN: Bool { UserDefaults.standard.object(forKey: "claudeRequireVPN") as? Bool ?? true }

    static func fetch() async throws -> ClaudeUsage {
        let token = try await ClaudeCredentials.load()
        if let exp = token.expiresAt, exp < Date() { throw ClaudeError.expired }

        let headers = [
            "Authorization": "Bearer \(token.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "BeaconHub/\(AppInfo.version)",
        ]

        let data: Data
        let code: Int
        if requireVPN {
            // Только через VPN: без туннеля или прокси запрос физически не уходит, см. VPNOnlyHTTP.
            let r = try await VPNOnlyHTTP.get(endpoint, headers: headers)
            (data, code) = (r.body, r.status)
        } else {
            var req = URLRequest(url: endpoint)
            req.timeoutInterval = 20
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (d, resp) = try await URLSession.shared.data(for: req)
            (data, code) = (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        switch code {
        case 200..<300: break
        case 401, 403: throw ClaudeError.expired
        case 429: throw ClaudeError.rateLimited
        default: throw ClaudeError.http(code)
        }
        return try parse(data, plan: token.subscription)
    }

    static func parse(_ data: Data, plan: String?) throws -> ClaudeUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse
        }
        var limits: [ClaudeLimit] = []

        // Новый формат: универсальный массив limits.
        if let arr = root["limits"] as? [[String: Any]] {
            for (i, l) in arr.enumerated() {
                let kind = l["kind"] as? String ?? "limit\(i)"
                let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                limits.append(ClaudeLimit(
                    id: "\(kind)-\(model ?? "")-\(i)",
                    kind: kind,
                    title: title(kind: kind, model: model),
                    percent: (l["percent"] as? NSNumber)?.doubleValue ?? 0,
                    resetsAt: (l["resets_at"] as? String).flatMap(DateParser.parse),
                    severity: l["severity"] as? String
                ))
            }
        }

        // Старый формат: отдельные ключи five_hour / seven_day.
        if limits.isEmpty {
            let legacy: [(key: String, kind: String, model: String?)] = [
                ("five_hour", "session", nil), ("seven_day", "weekly_all", nil),
                ("seven_day_opus", "weekly_scoped", "Opus"), ("seven_day_sonnet", "weekly_scoped", "Sonnet"),
            ]
            for item in legacy {
                guard let o = root[item.key] as? [String: Any],
                      let u = (o["utilization"] as? NSNumber)?.doubleValue else { continue }
                limits.append(ClaudeLimit(
                    id: item.key, kind: item.kind, title: title(kind: item.kind, model: item.model),
                    percent: u, resetsAt: (o["resets_at"] as? String).flatMap(DateParser.parse), severity: nil
                ))
            }
        }

        guard !limits.isEmpty else { throw ClaudeError.badResponse }
        return ClaudeUsage(limits: limits, plan: plan.map { $0.prefix(1).uppercased() + $0.dropFirst() })
    }

    static func title(kind: String, model: String?) -> String {
        switch kind {
        case "session": return "Сессия · 5 ч"
        case "weekly_all": return "Неделя · все модели"
        case "weekly_scoped": return "Неделя · \(model ?? "модель")"
        default: return model.map { "\(kind) · \($0)" } ?? kind
        }
    }
}
