import Foundation

enum TrackerError: LocalizedError {
    case noOrg, noToken, unauthorized, rateLimited, http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noOrg: return "Не указан ID организации трекера (Настройки → Трекер)."
        case .noToken: return "Нет токена трекера. Войди в настройках: Настройки → Трекер."
        case .unauthorized: return "Токен трекера недействителен или истёк. Получи новый в настройках."
        case .rateLimited: return "Трекер просит подождать (слишком много запросов), повторю позже."
        case .http(let code, let message): return "Трекер ответил \(code): \(message)"
        }
    }

    /// Переход требует комментарий (422 «Вы должны указать значения для полей comment»).
    var needsComment: Bool {
        if case .http(422, let message) = self { return message.lowercased().contains("comment") }
        return false
    }
}

/// Токен лежит в Keychain и читается через /usr/bin/security. Тот же токен использует MCP трекера в Claude Code:
/// `TRACKER_TOKEN=$(security find-generic-password -s beaconhub-yandex-tracker -w)`.
enum TrackerAuth {
    static let keychainService = "beaconhub-yandex-tracker"
    /// OAuth-приложение «Beacon Hub» на oauth.yandex.ru (права tracker:read, tracker:write).
    static let clientID = "383d88d822b64e83916508d402c347eb"
    static var authorizeURL: String { "https://oauth.yandex.ru/authorize?response_type=token&client_id=\(clientID)" }

    static func readToken() async -> String? {
        guard let r = try? await Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"]),
              r.status == 0 else { return nil }
        let token = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Пишем через `security`, а не через SecItem: так запись доступна утилите `security`,
    /// и MCP в Claude Code читает её без диалогов доступа.
    static func saveToken(_ token: String) async -> Bool {
        let r = try? await Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-a", NSUserName(),
                                                           "-s", keychainService, "-w", token])
        await TrackerAPI.tokenCache.reset()
        return r?.status == 0
    }
}

actor TokenCache {
    private var token: String?

    func get() async -> String? {
        if let token { return token }
        token = await TrackerAuth.readToken()
        return token
    }

    func reset() { token = nil }
}

/// REST API Яндекс Трекера v3.
enum TrackerAPI {
    static let base = URL(string: "https://api.tracker.yandex.net/v3/")!
    static let tokenCache = TokenCache()

    static var orgID: String { UserDefaults.standard.string(forKey: "trackerOrgId") ?? "" }
    static var orgIsCloud: Bool { UserDefaults.standard.object(forKey: "trackerOrgIsCloud") as? Bool ?? true }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = DateParser.parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
            }
            return date
        }
        return d
    }()

    // MARK: - Методы

    static func myself(token: String? = nil) async throws -> TMyself {
        try decoder.decode(TMyself.self, from: try await raw("GET", "myself", token: token))
    }

    static func search(_ query: String, perPage: Int = 50) async throws -> [TIssue] {
        let data = try await raw("POST", "issues/_search", query: [.init(name: "perPage", value: String(perPage))],
                                 body: ["query": query])
        return try decoder.decode([TIssue].self, from: data)
    }

    struct TStatus: Decodable, Identifiable, Hashable {
        let key: String
        let name: String
        let type: String?
        let order: Int?
        var id: String { key }
    }

    static func statuses() async throws -> [TStatus] {
        try decoder.decode([TStatus].self, from: try await raw("GET", "statuses"))
    }

    static func issue(_ key: String) async throws -> TIssue {
        try decoder.decode(TIssue.self, from: try await raw("GET", "issues/\(key)"))
    }

    static func transitions(_ key: String) async throws -> [TTransition] {
        try decoder.decode([TTransition].self, from: try await raw("GET", "issues/\(key)/transitions"))
    }

    static func executeTransition(_ key: String, _ transitionID: String, comment: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let comment, !comment.isEmpty { body["comment"] = comment }
        _ = try await raw("POST", "issues/\(key)/transitions/\(transitionID)/_execute", body: body)
    }

    static func comments(_ key: String) async throws -> [TComment] {
        try decoder.decode([TComment].self, from: try await raw("GET", "issues/\(key)/comments"))
    }

    static func addComment(_ key: String, text: String) async throws {
        _ = try await raw("POST", "issues/\(key)/comments", body: ["text": text])
    }

    static func addWorklog(_ key: String, start: Date, minutes: Int, comment: String?) async throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        var body: [String: Any] = ["start": f.string(from: start), "duration": TDuration.iso(minutes: minutes)]
        if let comment, !comment.isEmpty { body["comment"] = comment }
        _ = try await raw("POST", "issues/\(key)/worklog", body: body)
    }

    /// История изменений, свежие сверху. Формат полей разнородный, поэтому разбираем вручную.
    static func changelog(_ key: String, perPage: Int = 20) async throws -> [[String: Any]] {
        let data = try await raw("GET", "issues/\(key)/changelog",
                                 query: [.init(name: "perPage", value: String(perPage)), .init(name: "sort", value: "desc")])
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    // MARK: - Транспорт

    static func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil,
                    token explicitToken: String? = nil) async throws -> Data {
        let org = orgID
        guard !org.isEmpty else { throw TrackerError.noOrg }
        var resolved = explicitToken
        if resolved == nil { resolved = await tokenCache.get() }
        guard let token = resolved else { throw TrackerError.noToken }

        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(org, forHTTPHeaderField: orgIsCloud ? "X-Cloud-Org-ID" : "X-Org-ID")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            if explicitToken == nil { await tokenCache.reset() }
            throw TrackerError.unauthorized
        }
        if code == 429 { throw TrackerError.rateLimited }
        guard (200..<300).contains(code) else {
            throw TrackerError.http(code, errorMessage(data))
        }
        return data
    }

    private static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let msgs = obj["errorMessages"] as? [String], let first = msgs.first { return first }
            if let errors = obj["errors"] as? [String: String], let first = errors.first { return "\(first.key): \(first.value)" }
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}
