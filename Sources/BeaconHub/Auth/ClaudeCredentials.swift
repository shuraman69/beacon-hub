import Foundation

struct ClaudeToken {
    let accessToken: String
    let expiresAt: Date?
    let subscription: String?
}

/// Берёт OAuth-токен, который хранит Claude Code. Отдельный логин в приложении не нужен.
///
/// Токен читается через `/usr/bin/security`, а не через SecItem API: доступ к этой записи Keychain
/// уже выдан утилите `security` (через неё пишет сам Claude Code). Поэтому нет диалогов
/// «Разрешить доступ» после каждой пересборки приложения.
/// Сами мы токен не обновляем: это делает Claude Code, иначе можно сломать его refresh-token.
enum ClaudeCredentials {
    static let keychainService = "Claude Code-credentials"

    static func load() async throws -> ClaudeToken {
        var data: Data?
        if let r = try? await Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"]),
           r.status == 0 {
            data = Data(r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        if data == nil {
            // Запасной вариант: файловое хранилище (так Claude Code хранит токен на Linux и в старых версиях).
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            data = try? Data(contentsOf: file)
        }
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty
        else { throw ClaudeError.notLoggedIn }

        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeToken(accessToken: access, expiresAt: expires, subscription: oauth["subscriptionType"] as? String)
    }
}
