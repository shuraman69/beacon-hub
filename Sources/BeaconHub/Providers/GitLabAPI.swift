import Foundation

enum GitLabError: LocalizedError {
    case noAccount(String), noToken(String), unauthorized(String), http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAccount(let h): return "Нет аккаунта для \(h). Выполни glab auth login --hostname \(h) или добавь токен в настройках."
        case .noToken(let h): return "Для \(h) нет токена (glab хранит его в keyring?). Добавь токен вручную в настройках."
        case .unauthorized(let h): return "\(h): токен недействителен. Выполни glab auth login --hostname \(h)."
        case .http(let code, let body): return "GitLab ответил \(code). \(body)"
        }
    }
}

/// Тонкий REST-клиент GitLab. При 401 у glab-аккаунта просит glab обновить OAuth-токен и повторяет запрос.
enum GitLabAPI {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = DateParser.parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
            }
            return date
        }
        return d
    }()

    static func get<T: Decodable>(_ type: T.Type, host: String, path: String,
                                  query: [URLQueryItem] = []) async throws -> T {
        guard let account = GitLabAccounts.account(for: host) else { throw GitLabError.noAccount(host) }
        do {
            return try await perform(type, apiBase: account.apiBase, token: account.token, host: host, path: path, query: query)
        } catch GitLabError.unauthorized(_) where account.source == .glab {
            await GlabRefresher.shared.refresh(host: host)
            guard let fresh = GitLabAccounts.account(for: host) else { throw GitLabError.noAccount(host) }
            return try await perform(type, apiBase: fresh.apiBase, token: fresh.token, host: host, path: path, query: query)
        }
    }

    /// Проверка токена при ручном добавлении хоста.
    static func validate(host: String, token: String) async throws -> GLUser {
        guard let api = URL(string: "https://\(host)/api/v4/") else { throw GitLabError.noAccount(host) }
        return try await perform(GLUser.self, apiBase: api, token: token, host: host, path: "user", query: [])
    }

    private static func perform<T: Decodable>(_ type: T.Type, apiBase: URL, token: String?, host: String,
                                              path: String, query: [URLQueryItem]) async throws -> T {
        guard let token, !token.isEmpty else { throw GitLabError.noToken(host) }
        guard var comps = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw GitLabError.noAccount(host)
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw GitLabError.noAccount(host) }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw GitLabError.unauthorized(host) }
        guard (200..<300).contains(code) else {
            throw GitLabError.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return try decoder.decode(T.self, from: data)
    }
}
