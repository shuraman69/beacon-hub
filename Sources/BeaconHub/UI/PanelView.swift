import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case summary, tasks, notes, ci, claude
    var id: String { rawValue }
    var title: String {
        switch self {
        case .summary: return "Сводка"
        case .tasks: return "Задачи"
        case .notes: return "Заметки"
        case .ci: return "CI"
        case .claude: return "Claude"
        }
    }
    var icon: String {
        switch self {
        case .summary: return "square.grid.2x2"
        case .tasks: return "checklist"
        case .notes: return "note.text"
        case .ci: return "arrow.triangle.branch"
        case .claude: return "sparkle"
        }
    }
}

/// Содержимое всплывающей панели: вкладки сверху, инструменты снизу.
/// Сводка показывает только важное, подробности открываются по клику.
struct PanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @ObservedObject var tracker: TrackerStore
    @ObservedObject var notes: NotesStore
    let openSettings: () -> Void
    let runTool: (ToolAction) -> Void

    @State private var openedIssueKey: String?
    @State private var openedNote: (id: UUID, focusItems: Bool)?
    @State private var taskFilter: TaskFilter = .inProgress
    @State private var contentHeight: CGFloat = 200
    /// Область контента растёт по содержимому до этого предела, дальше включается скролл.
    private let maxScrollHeight: CGFloat = 540

    init(state: AppState, settings: AppSettings, openSettings: @escaping () -> Void,
         runTool: @escaping (ToolAction) -> Void) {
        self.state = state
        self.settings = settings
        self.tracker = state.tracker
        self.notes = state.notes
        self.openSettings = openSettings
        self.runTool = runTool
    }

    private var tabs: [PanelTab] {
        PanelTab.allCases.filter {
            switch $0 {
            case .summary: return true
            case .tasks: return settings.trackerEnabled
            case .notes: return settings.showNotes
            case .ci: return settings.showGitLab
            case .claude: return settings.showClaude
            }
        }
    }

    private var tab: PanelTab {
        let t = PanelTab(rawValue: settings.panelTab) ?? .summary
        return tabs.contains(t) ? t : .summary
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            ScrollView {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in contentHeight = h }
                    })
            }
            .frame(height: min(max(contentHeight, 60), maxScrollHeight))
            Divider()
            bottomBar
        }
        .frame(width: 390)
    }

    private func select(_ t: PanelTab, filter: TaskFilter? = nil) {
        settings.panelTab = t.rawValue
        if let filter { taskFilter = filter }
        if t != .tasks { openedIssueKey = nil }
        if t != .notes, let n = openedNote { notes.dropIfEmpty(n.id); openedNote = nil }
    }

    // MARK: Шапка и вкладки

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "light.beacon.max.fill").foregroundStyle(.orange)
            Text("Beacon Hub").font(.headline)
            Spacer()
            if let last = state.lastRefresh {
                TimelineView(.periodic(from: .now, by: 10)) { ctx in
                    Text(Fmt.relative(last, now: ctx.date)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await state.refresh(force: true) }
            } label: {
                if state.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.borderless)
            .help("Обновить")
            .disabled(state.isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { t in
                TabChip(title: t.title, icon: t.icon, showIcon: tabs.count <= 4, selected: t == tab, badge: badge(for: t)) { select(t) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func badge(for t: PanelTab) -> TabBadge? {
        switch t {
        case .tasks:
            return tracker.unreadCount > 0 ? .count(tracker.unreadCount) : nil
        case .ci:
            switch state.overallStatus {
            case .failed: return .dot(.red)
            case .running: return .dot(.blue)
            default: return nil
            }
        case .claude:
            if let p = state.claudeUsage?.session?.percent, p >= 80 { return .dot(.orange) }
            return nil
        case .summary, .notes:
            return nil
        }
    }

    // MARK: Содержимое

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch tab {
            case .summary:
                SummaryView(state: state, tracker: tracker, settings: settings, notes: notes,
                            go: { select($0, filter: $1) },
                            openIssue: { openedIssueKey = $0.key; select(.tasks) },
                            openNote: { openedNote = ($0, false); select(.notes) })
            case .tasks:
                if let key = openedIssueKey {
                    IssueDetailView(tracker: tracker, issueKey: key) { openedIssueKey = nil }
                } else {
                    TasksView(tracker: tracker, settings: settings, filter: $taskFilter,
                              open: { openedIssueKey = $0.key }, openSettings: openSettings)
                }
            case .notes:
                if let n = openedNote {
                    NoteDetailView(store: notes, tracker: tracker, id: n.id, focusItems: n.focusItems) { openedNote = nil }
                        .id(n.id)
                } else {
                    NotesView(store: notes) { openedNote = ($0, $1) }
                }
            case .ci:
                GitLabSection(state: state, settings: settings, openSettings: openSettings)
            case .claude:
                ClaudeSection(state: state)
            }
        }
        .padding(12)
    }

    // MARK: Низ: инструменты и системные кнопки

    private var bottomBar: some View {
        HStack(spacing: 6) {
            if settings.ocrEnabled {
                ToolButton(title: "Текст", systemImage: "text.viewfinder",
                           shortcut: settings.ocrShortcut?.display) { runTool(.captureText) }
            }
            if settings.clipboardEnabled {
                ToolButton(title: "Буфер", systemImage: "doc.on.clipboard",
                           shortcut: settings.clipboardShortcut?.display) { runTool(.clipboard) }
            }
            Spacer(minLength: 4)
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .help("Настройки")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Выйти")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

enum TabBadge {
    case count(Int)
    case dot(Color)
}

struct TabChip: View {
    let title: String
    let icon: String
    /// При пяти вкладках иконки не помещаются: оставляем только подписи.
    var showIcon = true
    let selected: Bool
    let badge: TabBadge?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if showIcon { Image(systemName: icon).font(.caption) }
                Text(title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1).fixedSize()
                switch badge {
                case .count(let n):
                    Text("\(n)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.red))
                case .dot(let color):
                    Circle().fill(color).frame(width: 7, height: 7)
                case nil:
                    EmptyView()
                }
            }
            .padding(.horizontal, showIcon ? 9 : 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : .clear)))
        .onHover { hovering = $0 }
    }
}

// MARK: - Claude

struct ClaudeSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        SectionCard(title: "Claude", systemImage: "sparkle") {
            if let plan = state.claudeUsage?.plan { Badge(text: plan, color: .orange) }
        } content: {
            if let usage = state.claudeUsage {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(usage.limits) { LimitRow(limit: $0, now: ctx.date) }
                    }
                }
            }
            if let error = state.claudeError {
                ErrorLine(text: error)
            } else if state.claudeUsage == nil {
                HStack { ProgressView().controlSize(.small); Text("Загружаю лимиты…").foregroundStyle(.secondary) }
            }
        }
    }
}

struct LimitRow: View {
    let limit: ClaudeLimit
    let now: Date

    private var color: Color {
        if limit.severity == "critical" || limit.percent >= 90 { return .red }
        if limit.severity == "warning" || limit.percent >= 70 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(limit.title).font(.callout)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            UsageBar(fraction: limit.percent / 100, color: color)
            if let reset = limit.resetsAt {
                Text(Fmt.reset(reset, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - GitLab

struct GitLabSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let openSettings: () -> Void

    private var multiHost: Bool { Set(settings.projects.map(\.host)).count > 1 }

    var body: some View {
        SectionCard(title: "GitLab CI/CD", systemImage: "arrow.triangle.branch") {
            if settings.onlyMyPipelines { Badge(text: "только мои") }
        } content: {
            if settings.projects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Проекты не выбраны.").foregroundStyle(.secondary)
                    Button("Выбрать проекты…", action: openSettings)
                }
            } else if state.gitlab.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Загружаю пайплайны…").foregroundStyle(.secondary) }
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.gitlab) { item in
                            ProjectBlock(item: item, showHost: multiHost, now: ctx.date)
                        }
                    }
                }
            }
        }
    }
}

struct ProjectBlock: View {
    let item: ProjectPipelines
    let showHost: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HoverRow(action: { openURL(item.project.webURL + "/-/pipelines") }) {
                HStack(spacing: 6) {
                    Text(item.project.name).font(.callout.weight(.semibold))
                    Text(item.project.namespace).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if showHost { Badge(text: shortHost(item.project.host)) }
                }
            }
            if let error = item.error {
                ErrorLine(text: error).padding(.horizontal, 6)
            }
            if item.pipelines.isEmpty && item.error == nil {
                Text("Пайплайнов нет").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            ForEach(item.pipelines) { PipelineRow(pipeline: $0, now: now) }
        }
    }

    private func shortHost(_ host: String) -> String {
        host == "gitlab.com" ? "gitlab.com" : String(host.split(separator: ".").first ?? Substring(host))
    }
}

struct PipelineRow: View {
    let pipeline: GLPipeline
    let now: Date

    private var timeText: String {
        let active = PipelineStatus.isActive(pipeline.status)
        if active, let started = pipeline.createdAt {
            return Fmt.duration(now.timeIntervalSince(started))
        }
        if let date = pipeline.updatedAt ?? pipeline.createdAt {
            return Fmt.relative(date, now: now)
        }
        return ""
    }

    var body: some View {
        HoverRow(action: { openURL(pipeline.webUrl) }) {
            HStack(spacing: 8) {
                Image(systemName: PipelineStyle.symbol(pipeline.status))
                    .foregroundStyle(PipelineStyle.color(pipeline.status))
                    .symbolEffect(.pulse, isActive: pipeline.status == "running")
                Text(pipeline.ref)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(timeText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .help("#\(pipeline.iid ?? pipeline.id) · \(PipelineStatus.title(pipeline.status))"
              + (pipeline.source.map { " · \($0)" } ?? "")
              + (pipeline.sha.map { " · \($0.prefix(8))" } ?? ""))
    }
}

enum ToolAction { case captureText, clipboard }

struct ToolButton: View {
    let title: String
    let systemImage: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title).font(.callout)
                Spacer(minLength: 2)
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
        .onHover { hovering = $0 }
    }
}
