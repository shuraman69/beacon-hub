import Foundation

/// Состояние трекера: списки задач, лента событий, таймер и действия над задачами.
@MainActor
final class TrackerStore: ObservableObject {
    @Published private(set) var lists: [TaskFilter: [TIssue]] = [:]
    @Published private(set) var me: TMyself?
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    @Published private(set) var events: [TrackerEvent] = []
    @Published private(set) var timer: TrackerTimer?

    let settings: AppSettings
    private let defaults = UserDefaults.standard
    private var lastEventsCheck: Date?
    /// После 429 делаем паузу, чтобы не усугублять.
    private var pausedUntil: Date?

    init(settings: AppSettings) {
        self.settings = settings
        if let data = defaults.data(forKey: "trackerTimer") {
            timer = try? JSONDecoder().decode(TrackerTimer.self, from: data)
        }
        if let data = defaults.data(forKey: "trackerEvents") {
            events = (try? JSONDecoder().decode([TrackerEvent].self, from: data)) ?? []
        }
        lastEventsCheck = defaults.object(forKey: "trackerEventsCheck") as? Date
    }

    var isConfigured: Bool { settings.trackerEnabled && !settings.trackerOrgId.isEmpty }
    var unreadCount: Int { events.filter { !$0.read }.count }

    // MARK: - Обновление

    func refresh() async {
        guard isConfigured else {
            lists = [:]
            return
        }
        if let until = pausedUntil, until > Date() { return }
        do {
            if me == nil { me = try await TrackerAPI.myself() }
            // Последовательно: на параллельные запросы трекер быстро отвечает 429.
            let inProgress = try await TrackerAPI.search(TaskFilter.inProgress.query!, perPage: 30)
            let waiting = try await TrackerAPI.search(TaskFilter.waiting.query!, perPage: 30)
            let mine = try await TrackerAPI.search(TaskFilter.mine.query!, perPage: 50)
            // Стабильная сортировка: по статусу (в работе → надо делать → беклог), внутри по дате обновления.
            let ranked = mine.enumerated().sorted { a, b in
                let ra = TaskFilter.rank(a.element.status.key), rb = TaskFilter.rank(b.element.status.key)
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
            lists = [.inProgress: inProgress, .waiting: waiting, .mine: ranked]
            error = nil
            loaded = true
            await checkEvents()
        } catch TrackerError.rateLimited {
            pausedUntil = Date().addingTimeInterval(120)
            Log.info("Tracker: 429, пауза 2 мин")
            if !loaded { self.error = TrackerError.rateLimited.localizedDescription }
        } catch {
            Log.info("Tracker: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    func issues(_ filter: TaskFilter) -> [TIssue] { lists[filter] ?? [] }

    /// Обновить одну задачу во всех списках (после смены статуса и т. п.).
    func reload(_ key: String) async {
        guard let fresh = try? await TrackerAPI.issue(key) else { return }
        for (filter, items) in lists {
            lists[filter] = items.map { $0.key == key ? fresh : $0 }
        }
    }

    // MARK: - События (уведомления)

    /// У трекера нет API уведомлений, поэтому ищем задачи, обновлённые после прошлой проверки,
    /// и разбираем их историю изменений. Свои собственные действия пропускаем.
    private func checkEvents() async {
        let now = Date()
        guard let since = lastEventsCheck else {
            setLastCheck(now) // первый запуск: старые события не вываливаем
            return
        }
        guard let meID = me.map({ String($0.uid) }) else { return }

        let query = #"(Assignee: me() OR Followers: me() OR Author: me() OR "Pending Reply From": me()) AND Updated: > now()-1d "Sort By": Updated DESC"#
        guard let updated = try? await TrackerAPI.search(query, perPage: 30) else { return }
        let fresh = updated.filter { ($0.updatedAt ?? .distantPast) > since }.prefix(15)

        var newEvents: [TrackerEvent] = []
        for issue in fresh {
            guard let log = try? await TrackerAPI.changelog(issue.key, perPage: 15) else { continue }
            for entry in log {
                guard let dateString = entry["updatedAt"] as? String, let date = DateParser.parse(dateString),
                      date > since else { continue }
                let author = entry["updatedBy"] as? [String: Any]
                let authorID = Self.idString(author?["id"])
                guard authorID != meID else { continue }
                if let event = Self.makeEvent(entry, issue: issue, meID: meID,
                                              author: author?["display"] as? String ?? "Кто-то", date: date),
                   isEnabled(event.kind), !events.contains(where: { $0.id == event.id }) {
                    newEvents.append(event)
                }
            }
        }
        setLastCheck(now)
        guard !newEvents.isEmpty else { return }

        newEvents.sort { $0.date > $1.date }
        events = Array((newEvents + events).prefix(100))
        saveEvents()
        notify(newEvents)
    }

    private static func idString(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private static func makeEvent(_ entry: [String: Any], issue: TIssue, meID: String,
                                  author: String, date: Date) -> TrackerEvent? {
        let id = entry["id"] as? String ?? UUID().uuidString
        let fields = entry["fields"] as? [[String: Any]] ?? []
        func field(_ name: String) -> [String: Any]? {
            fields.first { (($0["field"] as? [String: Any])?["id"] as? String) == name }
        }
        func make(_ kind: TrackerEvent.Kind, _ text: String) -> TrackerEvent {
            TrackerEvent(id: id, kind: kind, issueKey: issue.key, issueSummary: issue.summary,
                         text: text, author: author, date: date)
        }

        if let assignee = field("assignee"), let to = assignee["to"] as? [String: Any], idString(to["id"]) == meID {
            return make(.assigned, "Назначил(а) задачу на тебя")
        }
        if let pending = field("pendingReplyFrom"), let to = pending["to"] as? [[String: Any]],
           to.contains(where: { idString($0["id"]) == meID }) {
            return make(.mention, "Ждёт твоего ответа")
        }
        if let status = field("status") {
            let from = (status["from"] as? [String: Any])?["display"] as? String ?? "?"
            let to = (status["to"] as? [String: Any])?["display"] as? String ?? "?"
            return make(.status, "\(from) → \(to)")
        }
        if let comments = entry["comments"] as? [String: Any], comments["added"] != nil {
            return make(.comment, "Новый комментарий")
        }
        return nil
    }

    private func isEnabled(_ kind: TrackerEvent.Kind) -> Bool {
        switch kind {
        case .assigned: return settings.trackerNotifyAssigned
        case .mention: return settings.trackerNotifyMention
        case .comment: return settings.trackerNotifyComment
        case .status: return settings.trackerNotifyStatus
        }
    }

    private func notify(_ items: [TrackerEvent]) {
        if items.count > 3 {
            Notifier.shared.send(title: "Трекер: \(items.count) новых событий",
                                 body: items.prefix(3).map { "\($0.issueKey): \($0.text)" }.joined(separator: "\n"),
                                 url: nil)
            return
        }
        for e in items {
            Notifier.shared.send(title: "\(e.issueKey) · \(e.author)", body: "\(e.text)\n\(e.issueSummary)",
                                 url: "https://tracker.yandex.ru/\(e.issueKey)")
        }
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        events = events.map { var e = $0; e.read = true; return e }
        saveEvents()
    }

    func clearEvents() {
        events = []
        saveEvents()
    }

    private func setLastCheck(_ date: Date) {
        lastEventsCheck = date
        defaults.set(date, forKey: "trackerEventsCheck")
    }

    private func saveEvents() {
        defaults.set(try? JSONEncoder().encode(events), forKey: "trackerEvents")
    }

    // MARK: - Действия

    func transitions(for key: String) async throws -> [TTransition] {
        try await TrackerAPI.transitions(key)
    }

    func execute(_ transition: TTransition, on issue: TIssue) async throws {
        try await TrackerAPI.executeTransition(issue.key, transition.id)
        await reload(issue.key)
        Task { await refresh() } // задача могла переехать между списками
    }

    func logTime(_ issue: TIssue, minutes: Int, comment: String? = nil) async throws {
        try await TrackerAPI.addWorklog(issue.key, start: Date().addingTimeInterval(-Double(minutes) * 60),
                                       minutes: minutes, comment: comment)
        await reload(issue.key)
    }

    func addComment(_ issue: TIssue, text: String) async throws {
        try await TrackerAPI.addComment(issue.key, text: text)
    }

    // MARK: - Таймер

    func startTimer(_ issue: TIssue) async {
        if let current = timer {
            if current.key == issue.key { return }
            await stopTimer(log: true)
        }
        timer = TrackerTimer(key: issue.key, summary: issue.summary, startedAt: Date())
        saveTimer()
        Toast.show("Таймер запущен", subtitle: "\(issue.key) · \(issue.summary)", systemImage: "timer", color: .blue)
    }

    /// Останавливает таймер. При `log` списывает время (минимум 1 минута) в задачу.
    func stopTimer(log: Bool) async {
        guard let current = timer else { return }
        timer = nil
        saveTimer()
        guard log else {
            Toast.show("Таймер сброшен", subtitle: current.key, systemImage: "timer", color: .gray)
            return
        }
        let minutes = max(1, Int((Date().timeIntervalSince(current.startedAt) / 60).rounded()))
        do {
            try await TrackerAPI.addWorklog(current.key, start: current.startedAt, minutes: minutes, comment: nil)
            Toast.show("Списано \(Fmt.duration(Double(minutes) * 60))", subtitle: "\(current.key) · \(current.summary)",
                       systemImage: "clock.badge.checkmark")
            await reload(current.key)
        } catch {
            // Не теряем время: возвращаем таймер, чтобы можно было попробовать ещё раз.
            timer = current
            saveTimer()
            Toast.show("Не удалось списать время", subtitle: error.localizedDescription,
                       systemImage: "exclamationmark.triangle.fill", color: .orange, duration: 5)
        }
    }

    private func saveTimer() {
        if let timer, let data = try? JSONEncoder().encode(timer) {
            defaults.set(data, forKey: "trackerTimer")
        } else {
            defaults.removeObject(forKey: "trackerTimer")
        }
    }
}
