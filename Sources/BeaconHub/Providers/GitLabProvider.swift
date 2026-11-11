import Foundation

/// Кэш username по хостам, нужен для фильтра «только мои пайплайны».
actor GitLabUserCache {
    static let shared = GitLabUserCache()
    private var cache: [String: String] = [:]

    func username(for host: String) async -> String? {
        if let u = cache[host] { return u }
        if let u = GitLabAccounts.account(for: host)?.user {
            cache[host] = u
            return u
        }
        if let me = try? await GitLabAPI.get(GLUser.self, host: host, path: "user") {
            cache[host] = me.username
            return me.username
        }
        return nil
    }
}

enum GitLabProvider {
    static func fetch(projects: [ProjectRef], perProject: Int, onlyMine: Bool) async -> [ProjectPipelines] {
        await withTaskGroup(of: (Int, ProjectPipelines).self) { group in
            for (index, project) in projects.enumerated() {
                group.addTask {
                    (index, await fetchOne(project, perProject: perProject, onlyMine: onlyMine))
                }
            }
            var results = [ProjectPipelines?](repeating: nil, count: projects.count)
            for await (index, item) in group { results[index] = item }
            return results.compactMap { $0 }
        }
    }

    static func fetchOne(_ project: ProjectRef, perProject: Int, onlyMine: Bool) async -> ProjectPipelines {
        var query = [
            URLQueryItem(name: "per_page", value: String(perProject)),
            URLQueryItem(name: "order_by", value: "id"),
            URLQueryItem(name: "sort", value: "desc"),
        ]
        if onlyMine, let user = await GitLabUserCache.shared.username(for: project.host) {
            query.append(URLQueryItem(name: "username", value: user))
        }
        do {
            let pipelines = try await GitLabAPI.get([GLPipeline].self, host: project.host,
                                                    path: "projects/\(project.projectId)/pipelines", query: query)
            return ProjectPipelines(project: project, pipelines: pipelines, error: nil)
        } catch {
            Log.info("GitLab \(project.path): \(error.localizedDescription)")
            return ProjectPipelines(project: project, pipelines: [], error: error.localizedDescription)
        }
    }

    /// Поиск среди проектов, где пользователь участник. Без запроса отдаёт недавно активные.
    static func searchProjects(host: String, query: String) async throws -> [GLProject] {
        var items = [
            URLQueryItem(name: "membership", value: "true"),
            URLQueryItem(name: "simple", value: "true"),
            URLQueryItem(name: "per_page", value: "30"),
            URLQueryItem(name: "order_by", value: "last_activity_at"),
        ]
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items.append(URLQueryItem(name: "search", value: q))
            items.append(URLQueryItem(name: "search_namespaces", value: "true"))
        }
        return try await GitLabAPI.get([GLProject].self, host: host, path: "projects", query: items)
    }
}
