import Combine
import Foundation

/// Состояние всех источников и фоновый цикл опроса.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var claudeUsage: ClaudeUsage?
    @Published private(set) var claudeError: String?
    @Published private(set) var gitlab: [ProjectPipelines] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    let settings: AppSettings
    let tracker: TrackerStore
    let notes = NotesStore()
    private var loopTask: Task<Void, Never>?
    private var lastClaudeFetch: Date?
    private var knownStatuses: [String: String] = [:]
    private var seenProjects: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    /// Claude опрашиваем не чаще раза в 90 с: эндпоинт неофициальный, лишняя нагрузка ни к чему.
    private let claudeMinInterval: TimeInterval = 90
    /// Пока какой-то пайплайн идёт, GitLab опрашиваем чаще.
    private let activeInterval: TimeInterval = 15

    init(settings: AppSettings) {
        self.settings = settings
        self.tracker = TrackerStore(settings: settings)
        // Изменили список проектов или фильтры: обновляемся сразу.
        Publishers.Merge3(
            settings.$projects.map { _ in () },
            settings.$onlyMyPipelines.map { _ in () },
            settings.$pipelinesPerProject.map { _ in () }
        )
        .dropFirst(3)
        .debounce(for: .seconds(0.8), scheduler: RunLoop.main)
        .sink { [weak self] in Task { await self?.refreshGitLab() } }
        .store(in: &cancellables)
    }

    func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.hasActivePipelines
                    ? min(self.settings.refreshInterval, self.activeInterval)
                    : self.settings.refreshInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        async let g: Void = refreshGitLab()
        async let c: Void = refreshClaude(force: force)
        async let t: Void = tracker.refresh()
        _ = await (g, c, t)
        isRefreshing = false
        lastRefresh = Date()
        let pipelines = gitlab.reduce(0) { $0 + $1.pipelines.count }
        let claude = claudeUsage?.limits.map { "\($0.kind)=\(Int($0.percent))%" }.joined(separator: " ") ?? "—"
        let tasks = TaskFilter.allCases.map { "\($0.rawValue)=\(tracker.issues($0).count)" }.joined(separator: " ")
        Log.info("обновлено: GitLab \(gitlab.count) проектов / \(pipelines) пайплайнов, Claude \(claude), Трекер \(tasks) событий=\(tracker.events.count)\(tracker.error.map { " ошибка: \($0)" } ?? "")")
    }

    /// Вызывается при открытии панели: если данные старше 30 с, тихо обновляем.
    func refreshIfStale() {
        if let last = lastRefresh, Date().timeIntervalSince(last) < 30 { return }
        Task { await refresh() }
    }

    // MARK: - Claude

    private func refreshClaude(force: Bool) async {
        guard settings.showClaude else { return }
        if !force, let last = lastClaudeFetch,
           Date().timeIntervalSince(last) < max(settings.refreshInterval, claudeMinInterval) { return }
        lastClaudeFetch = Date()
        do {
            claudeUsage = try await ClaudeUsageProvider.fetch()
            claudeError = nil
        } catch {
            Log.info("Claude: \(error.localizedDescription)")
            claudeError = error.localizedDescription
        }
    }

    // MARK: - GitLab

    func refreshGitLab() async {
        guard settings.showGitLab else { return }
        let projects = settings.projects
        guard !projects.isEmpty else {
            gitlab = []
            return
        }
        var result = await GitLabProvider.fetch(projects: projects,
                                                perProject: settings.pipelinesPerProject,
                                                onlyMine: settings.onlyMyPipelines)
        // При ошибке сети оставляем последние известные пайплайны и показываем ошибку рядом.
        let previous = Dictionary(uniqueKeysWithValues: gitlab.map { ($0.id, $0) })
        for i in result.indices where result[i].error != nil {
            if let old = previous[result[i].id] { result[i].pipelines = old.pipelines }
        }
        detectTransitions(result)
        gitlab = result
    }

    private func detectTransitions(_ items: [ProjectPipelines]) {
        for item in items where item.error == nil {
            let firstLoad = !seenProjects.contains(item.id)
            for p in item.pipelines {
                let key = "\(item.project.host)#\(p.id)"
                let old = knownStatuses[key]
                knownStatuses[key] = p.status
                guard !firstLoad, old != p.status, PipelineStatus.isFinal(p.status) else { continue }
                // Был активен и завершился, либо появился новый и уже упал.
                guard old.map(PipelineStatus.isActive) ?? (p.status == "failed") else { continue }
                notify(project: item.project, pipeline: p)
            }
            seenProjects.insert(item.id)
        }
    }

    private func notify(project: ProjectRef, pipeline p: GLPipeline) {
        switch p.status {
        case "failed" where settings.notifyFailed:
            Notifier.shared.send(title: "❌ \(project.name): пайплайн упал",
                                 body: "\(p.ref) · #\(p.iid ?? p.id)", url: p.webUrl)
        case "success" where settings.notifySuccess:
            Notifier.shared.send(title: "✅ \(project.name): пайплайн прошёл",
                                 body: "\(p.ref) · #\(p.iid ?? p.id)", url: p.webUrl)
        default:
            break
        }
    }

    // MARK: - Сводка

    /// Для сводки: последние пайплайны веток, которые упали или идут.
    var ciHighlights: [(project: ProjectRef, pipeline: GLPipeline)] {
        var seen: Set<String> = []
        var out: [(ProjectRef, GLPipeline)] = []
        for item in gitlab {
            for p in item.pipelines where !seen.contains("\(item.id)|\(p.ref)") {
                seen.insert("\(item.id)|\(p.ref)")
                if p.status == "failed" || PipelineStatus.isActive(p.status) { out.append((item.project, p)) }
            }
        }
        return out.sorted { a, b in (a.1.status == "failed" ? 0 : 1) < (b.1.status == "failed" ? 0 : 1) }
    }

    var hasActivePipelines: Bool {
        gitlab.contains { $0.pipelines.contains { PipelineStatus.isActive($0.status) } }
    }

    /// Сводный статус для иконки: смотрим на последний пайплайн каждой ветки каждого проекта.
    var overallStatus: OverallStatus {
        guard settings.showGitLab, !gitlab.isEmpty else { return .unknown }
        var latest: [String: String] = [:]
        for item in gitlab {
            for p in item.pipelines where latest["\(item.id)|\(p.ref)"] == nil {
                latest["\(item.id)|\(p.ref)"] = p.status
            }
        }
        if latest.values.contains("failed") { return .failed }
        if latest.values.contains(where: PipelineStatus.isActive) { return .running }
        return .ok
    }
}
