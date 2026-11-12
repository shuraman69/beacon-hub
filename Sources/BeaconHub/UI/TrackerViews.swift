import AppKit
import SwiftUI

enum StatusStyle {
    static func color(_ statusType: String?) -> Color {
        switch statusType {
        case "inProgress": return .blue
        case "paused": return .orange
        case "done": return .green
        case "cancelled": return .gray
        default: return .secondary
        }
    }
}

@MainActor
func copyToPasteboard(_ text: String, toast: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    Toast.show(toast, subtitle: text, systemImage: "doc.on.doc")
}

// MARK: - Список задач

struct TasksView: View {
    @ObservedObject var tracker: TrackerStore
    @ObservedObject var settings: AppSettings
    @Binding var filter: TaskFilter
    let open: (TIssue) -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(TaskFilter.allCases) { f in
                    FilterChip(title: f.title, count: count(f), highlight: f == .events && tracker.unreadCount > 0,
                               selected: f == filter) { filter = f }
                        .help(f == .waiting ? "Ждут твоего ответа (призыв в задаче)" : f.title)
                }
            }

            if !tracker.isConfigured {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Трекер не настроен.").foregroundStyle(.secondary)
                    Button("Открыть настройки", action: openSettings)
                }
            } else if let error = tracker.error, !tracker.loaded {
                ErrorLine(text: error)
            } else if filter == .events {
                EventsList(tracker: tracker, open: open)
            } else {
                let items = tracker.issues(filter)
                if !tracker.loaded {
                    HStack { ProgressView().controlSize(.small); Text("Загружаю задачи…").foregroundStyle(.secondary) }
                } else if items.isEmpty {
                    Text("Пусто").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    VStack(spacing: 2) {
                        ForEach(items) { issue in
                            IssueRow(tracker: tracker, issue: issue) { open(issue) }
                        }
                    }
                }
                if let error = tracker.error, tracker.loaded { ErrorLine(text: error) }
            }
        }
    }

    private func count(_ f: TaskFilter) -> Int? {
        f == .events ? (tracker.unreadCount > 0 ? tracker.unreadCount : nil) : tracker.issues(f).count
    }
}

struct FilterChip: View {
    let title: String
    let count: Int?
    var highlight = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1).fixedSize()
                if let count {
                    Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(highlight ? .white : .secondary)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(highlight ? Color.red : Color.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Capsule().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12)))
        .background(Capsule().fill(selected ? Color.accentColor.opacity(0.12) : .clear))
    }
}

/// Строка задачи: по клику открывается карточка, при наведении появляются быстрые действия.
struct IssueRow: View {
    @ObservedObject var tracker: TrackerStore
    let issue: TIssue
    let open: () -> Void
    @State private var hovering = false

    private var timerHere: Bool { tracker.timer?.key == issue.key }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Badge(text: issue.status.display, color: StatusStyle.color(issue.statusType?.key))
                    if timerHere {
                        Image(systemName: "timer").font(.caption).foregroundStyle(.blue)
                    }
                }
                Text(issue.summary).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 4)
            if hovering {
                QuickActions(tracker: tracker, issue: issue)
            } else if let date = issue.updatedAt {
                Text(Fmt.relative(date)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu { IssueMenuItems(tracker: tracker, issue: issue) }
    }
}

/// Кнопки, которые появляются при наведении: таймер и быстрое списание времени.
struct QuickActions: View {
    @ObservedObject var tracker: TrackerStore
    let issue: TIssue

    var body: some View {
        HStack(spacing: 2) {
            Button {
                Task {
                    if tracker.timer?.key == issue.key { await tracker.stopTimer(log: true) }
                    else { await tracker.startTimer(issue) }
                }
            } label: {
                Image(systemName: tracker.timer?.key == issue.key ? "stop.circle.fill" : "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help(tracker.timer?.key == issue.key ? "Остановить таймер и списать" : "Запустить таймер")

            Menu {
                ForEach([15, 30, 60, 120], id: \.self) { m in
                    Button("Списать \(Fmt.duration(Double(m) * 60))") { log(m) }
                }
            } label: {
                Image(systemName: "clock.badge.checkmark").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Списать время")
        }
    }

    private func log(_ minutes: Int) {
        Task {
            do {
                try await tracker.logTime(issue, minutes: minutes)
                Toast.show("Списано \(Fmt.duration(Double(minutes) * 60))", subtitle: issue.key,
                           systemImage: "clock.badge.checkmark")
            } catch {
                Toast.show("Не удалось списать", subtitle: error.localizedDescription,
                           systemImage: "exclamationmark.triangle.fill", color: .orange, duration: 4)
            }
        }
    }
}

/// Пункты контекстного меню задачи (правый клик).
struct IssueMenuItems: View {
    @ObservedObject var tracker: TrackerStore
    let issue: TIssue

    var body: some View {
        if tracker.timer?.key == issue.key {
            Button("Остановить таймер и списать") { Task { await tracker.stopTimer(log: true) } }
        } else {
            Button("Запустить таймер") { Task { await tracker.startTimer(issue) } }
        }
        Menu("Списать время") {
            ForEach([15, 30, 60, 120], id: \.self) { m in
                Button(Fmt.duration(Double(m) * 60)) {
                    Task { try? await tracker.logTime(issue, minutes: m) }
                }
            }
        }
        Divider()
        Button("Копировать ключ") { copyToPasteboard(issue.key, toast: "Ключ скопирован") }
        Button("Копировать имя ветки") { copyToPasteboard(issue.branchName, toast: "Ветка скопирована") }
        Button("Копировать ссылку") { copyToPasteboard(issue.webURL, toast: "Ссылка скопирована") }
        Divider()
        Button("Открыть в трекере") { openURL(issue.webURL) }
    }
}

/// Компактная строка для сводки.
struct CompactIssueRow: View {
    let issue: TIssue
    let timerRunning: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: 6) {
                Circle().fill(StatusStyle.color(issue.statusType?.key)).frame(width: 7, height: 7)
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(issue.summary).font(.callout).lineLimit(1)
                Spacer(minLength: 2)
                if timerRunning { Image(systemName: "timer").font(.caption).foregroundStyle(.blue) }
            }
        }
    }
}

// MARK: - Лента событий

struct EventsList: View {
    @ObservedObject var tracker: TrackerStore
    let open: (TIssue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if tracker.events.isEmpty {
                Text("Пока событий нет. Здесь появятся назначения, призывы, комментарии и смены статусов в твоих задачах.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                HStack {
                    Spacer()
                    Button("Очистить") { tracker.clearEvents() }.buttonStyle(.link).font(.caption)
                }
                ForEach(tracker.events.prefix(40)) { e in
                    HoverRow(action: { openEvent(e) }) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: e.icon).foregroundStyle(e.read ? Color.secondary : Color.accentColor)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(e.issueKey).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(e.author).font(.caption.weight(.medium))
                                    Spacer()
                                    Text(Fmt.relative(e.date)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Text(e.text).font(.callout.weight(e.read ? .regular : .semibold))
                                Text(e.issueSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            // Открыл ленту: всё прочитано (с небольшой задержкой, чтобы успеть увидеть выделение).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tracker.markAllRead() }
        }
    }

    private func openEvent(_ e: TrackerEvent) {
        if let issue = TaskFilter.allCases.lazy.flatMap({ tracker.issues($0) }).first(where: { $0.key == e.issueKey }) {
            open(issue)
        } else {
            openURL("https://tracker.yandex.ru/\(e.issueKey)")
        }
    }
}

// MARK: - Карточка задачи

struct IssueDetailView: View {
    @ObservedObject var tracker: TrackerStore
    let issueKey: String
    let back: () -> Void

    @State private var loadedIssue: TIssue?
    @State private var transitions: [TTransition]?
    @State private var comments: [TComment]?
    @State private var customTime = ""
    @State private var logComment = ""
    @State private var commentText = ""
    @State private var busy = false
    @State private var message: (text: String, isError: Bool)?
    /// Переход, который ждёт комментария, и сам текст.
    @State private var pendingTransition: TTransition?
    @State private var transitionComment = ""
    @FocusState private var transitionCommentFocused: Bool

    private var issue: TIssue? {
        TaskFilter.allCases.lazy.flatMap { tracker.issues($0) }.first { $0.key == issueKey } ?? loadedIssue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: back) { Label("Назад", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text(issueKey).font(.callout.monospaced()).foregroundStyle(.secondary)
                Button { openURL("https://tracker.yandex.ru/\(issueKey)") } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Открыть в трекере")
            }

            if let issue {
                content(issue)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Загружаю…").foregroundStyle(.secondary) }
            }
        }
        .task(id: issueKey) { await load() }
    }

    @ViewBuilder private func content(_ issue: TIssue) -> some View {
        Text(issue.summary).font(.headline).fixedSize(horizontal: false, vertical: true)

        // Статус и метаданные
        HStack(spacing: 8) {
            Menu {
                if let transitions {
                    if transitions.isEmpty { Text("Нет доступных переходов") }
                    ForEach(transitions) { t in
                        Button(t.display == t.to.display ? t.display : "\(t.display) → \(t.to.display)") {
                            startTransition(t, on: issue)
                        }
                    }
                } else {
                    Text("Загружаю переходы…")
                }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(StatusStyle.color(issue.statusType?.key)).frame(width: 8, height: 8)
                    Text(issue.status.display)
                }
            }
            .fixedSize()
            .help("Сменить статус")

            if let p = issue.priority { Badge(text: p.display) }
            Spacer()
            if let spent = TDuration.display(issue.spent) {
                Label(spent, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            }
        }

        if let t = pendingTransition { transitionCommentForm(t, issue) }

        // Таймер
        timerRow(issue)

        // Списание времени
        VStack(alignment: .leading, spacing: 6) {
            Text("Списать время").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach([15, 30, 60, 120], id: \.self) { m in
                    Button(m < 60 ? "\(m)м" : "\(m / 60)ч") { log(issue, minutes: m) }
                        .disabled(busy)
                }
                TextField("1ч 30м", text: $customTime)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit { logCustom(issue) }
                Button { logCustom(issue) } label: { Image(systemName: "checkmark") }
                    .disabled(TDuration.parseMinutes(customTime) == nil || busy)
            }
            .controlSize(.small)
            TextField("Комментарий к списанию (необязательно)", text: $logComment)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }

        // Комментарий
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Написать комментарий…", text: $commentText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                let text = commentText
                run { try await tracker.addComment(issue, text: text) } success: {
                    commentText = ""
                    Task { await loadComments() }
                    return "Комментарий отправлен"
                }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        }

        // Копирование
        HStack(spacing: 6) {
            Button { copyToPasteboard(issue.key, toast: "Ключ скопирован") } label: { Label("Ключ", systemImage: "number") }
            Button { copyToPasteboard(issue.branchName, toast: "Ветка скопирована") } label: {
                Label("Ветка", systemImage: "arrow.triangle.branch")
            }
            .help(issue.branchName)
            Button { copyToPasteboard(issue.webURL, toast: "Ссылка скопирована") } label: { Label("Ссылка", systemImage: "link") }
        }
        .controlSize(.small)

        if let message {
            if message.isError {
                ErrorLine(text: message.text)
            } else {
                Label(message.text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
        }

        // Последние комментарии
        if let comments, !comments.isEmpty {
            Divider()
            Text("Последние комментарии").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(comments.suffix(3).reversed()) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.createdBy?.display ?? "").font(.caption.weight(.medium))
                        Spacer()
                        if let d = c.createdAt { Text(Fmt.relative(d)).font(.caption2).foregroundStyle(.tertiary) }
                    }
                    Text(c.richText).font(.callout).lineLimit(8).textSelection(.enabled)
                        .tint(.accentColor)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    @ViewBuilder private func timerRow(_ issue: TIssue) -> some View {
        if let timer = tracker.timer, timer.key == issue.key {
            HStack {
                Image(systemName: "timer").foregroundStyle(.blue)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Fmt.clock(ctx.date.timeIntervalSince(timer.startedAt)))
                        .font(.body.monospacedDigit().weight(.semibold))
                }
                Spacer()
                Button("Стоп и списать") { Task { await tracker.stopTimer(log: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Сбросить") { Task { await tracker.stopTimer(log: false) } }
            }
            .controlSize(.small)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1)))
        } else {
            Button {
                Task { await tracker.startTimer(issue) }
            } label: {
                Label(tracker.timer == nil ? "Запустить таймер" : "Переключить таймер сюда (\(tracker.timer!.key) спишется)",
                      systemImage: "play.fill")
            }
            .controlSize(.small)
        }
    }

    /// Поле комментария к переходу: текст подставлен заранее, его можно поправить.
    private func transitionCommentForm(_ t: TTransition, _ issue: TIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.blue)
                Text("Перевести в «\(t.to.display)»").font(.callout.weight(.semibold))
                Spacer()
            }
            TextField("Комментарий к переходу", text: $transitionComment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($transitionCommentFocused)
                .onSubmit { executeTransition(t, on: issue, comment: transitionComment) }
            HStack {
                Text("Трекер требует комментарий для этого перехода").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { pendingTransition = nil }
                Button("Перевести") { executeTransition(t, on: issue, comment: transitionComment) }
                    .buttonStyle(.borderedProminent)
                    .disabled(transitionComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1)))
    }

    // MARK: Действия

    private func startTransition(_ t: TTransition, on issue: TIssue) {
        if TransitionComments.isRequired(t, issue) {
            askComment(t)
        } else {
            executeTransition(t, on: issue, comment: nil)
        }
    }

    private func askComment(_ t: TTransition) {
        transitionComment = TransitionComments.defaultText(for: t)
        pendingTransition = t
        message = nil
        DispatchQueue.main.async { transitionCommentFocused = true }
    }

    private func executeTransition(_ t: TTransition, on issue: TIssue, comment: String?) {
        let text = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            do {
                try await tracker.execute(t, on: issue, comment: text)
                if let text, !text.isEmpty { TransitionComments.remember(text, for: t) }
                pendingTransition = nil
                message = ("Статус: \(t.to.display)", false)
                await loadTransitions()
            } catch let error as TrackerError where error.needsComment && (text ?? "").isEmpty {
                // Без комментария не пускает: запоминаем и показываем поле с текстом по умолчанию.
                TransitionComments.markRequired(t, issue)
                askComment(t)
            } catch {
                message = (error.localizedDescription, true)
            }
            busy = false
        }
    }

    private func log(_ issue: TIssue, minutes: Int) {
        let comment = logComment
        run { try await tracker.logTime(issue, minutes: minutes, comment: comment) } success: {
            logComment = ""
            customTime = ""
            return "Списано \(Fmt.duration(Double(minutes) * 60))"
        }
    }

    private func logCustom(_ issue: TIssue) {
        guard let minutes = TDuration.parseMinutes(customTime) else { return }
        log(issue, minutes: minutes)
    }

    private func run(_ action: @escaping () async throws -> Void, success: @escaping () -> String) {
        busy = true
        Task {
            do {
                try await action()
                message = (success(), false)
            } catch {
                message = (error.localizedDescription, true)
            }
            busy = false
        }
    }

    private func load() async {
        if issue == nil { loadedIssue = try? await TrackerAPI.issue(issueKey) }
        async let t: Void = loadTransitions()
        async let c: Void = loadComments()
        _ = await (t, c)
    }

    private func loadTransitions() async {
        do {
            transitions = try await tracker.transitions(for: issueKey)
        } catch {
            Log.info("Переходы \(issueKey): \(error)")
            transitions = []
        }
    }

    private func loadComments() async {
        do {
            comments = try await TrackerAPI.comments(issueKey)
        } catch {
            Log.info("Комментарии \(issueKey): \(error)")
        }
    }
}
