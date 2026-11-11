import Foundation

// MARK: - GitLab

/// Проект, выбранный пользователем для отслеживания (хранится в настройках).
struct ProjectRef: Codable, Hashable, Identifiable {
    var host: String
    var projectId: Int
    var path: String
    var webURL: String

    var id: String { "\(host)#\(projectId)" }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var namespace: String {
        let parts = path.split(separator: "/")
        return parts.dropLast().joined(separator: "/")
    }
}

struct GLProject: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let pathWithNamespace: String
    let webUrl: String
}

struct GLUser: Decodable {
    let id: Int
    let username: String
}

struct GLPipeline: Decodable, Identifiable, Hashable {
    let id: Int
    let iid: Int?
    let status: String
    let ref: String
    let sha: String?
    let webUrl: String
    let source: String?
    let createdAt: Date?
    let updatedAt: Date?
}

struct ProjectPipelines: Identifiable {
    var project: ProjectRef
    var pipelines: [GLPipeline]
    var error: String?
    var id: String { project.id }
}

enum PipelineStatus {
    static let active: Set<String> = ["created", "waiting_for_resource", "preparing", "pending", "running"]
    static let final: Set<String> = ["success", "failed", "canceled"]

    static func isActive(_ s: String) -> Bool { active.contains(s) }
    static func isFinal(_ s: String) -> Bool { final.contains(s) }

    static func title(_ s: String) -> String {
        switch s {
        case "success": return "успешно"
        case "failed": return "упал"
        case "running": return "идёт"
        case "pending", "created", "waiting_for_resource", "preparing": return "в очереди"
        case "canceled": return "отменён"
        case "skipped": return "пропущен"
        case "manual": return "ждёт запуска"
        case "scheduled": return "запланирован"
        default: return s
        }
    }
}

enum OverallStatus {
    case unknown, ok, running, failed
}

// MARK: - Claude

struct ClaudeLimit: Identifiable, Equatable {
    let id: String
    let kind: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let severity: String?
}

struct ClaudeUsage: Equatable {
    let limits: [ClaudeLimit]
    let plan: String?

    var session: ClaudeLimit? { limits.first { $0.kind == "session" } }
    var weekly: ClaudeLimit? { limits.first { $0.kind == "weekly_all" } }
}
