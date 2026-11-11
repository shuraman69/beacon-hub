import SwiftUI

/// Вкладка «Сводка»: только то, что требует внимания. Каждая карточка ведёт в свою вкладку.
struct SummaryView: View {
    @ObservedObject var state: AppState
    @ObservedObject var tracker: TrackerStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var notes: NotesStore
    let go: (PanelTab, TaskFilter?) -> Void
    let openIssue: (TIssue) -> Void
    let openNote: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let timer = tracker.timer {
                TimerCard(tracker: tracker, timer: timer)
            }
            if settings.showNotes && !notes.pinned.isEmpty {
                PinnedNotesCard(store: notes, openAll: { go(.notes, nil) }, open: openNote)
            }
            if settings.trackerEnabled { trackerCard }
            if settings.showGitLab { ciCard }
            if settings.showClaude { claudeCard }
        }
    }

    // MARK: Трекер

    private var trackerCard: some View {
        SectionCard(title: "Трекер", systemImage: "checklist") {
            Button("Все задачи →") { go(.tasks, .inProgress) }.buttonStyle(.link).font(.caption)
        } content: {
            if !tracker.isConfigured {
                Text("Не настроен: укажи организацию и токен в настройках.").font(.caption).foregroundStyle(.secondary)
            } else if let error = tracker.error, !tracker.loaded {
                ErrorLine(text: error)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        CounterPill(icon: "bell.fill", text: "\(tracker.unreadCount) новых",
                                    color: tracker.unreadCount > 0 ? .red : .secondary) { go(.tasks, .events) }
                        CounterPill(icon: "at", text: "ждут: \(tracker.issues(.waiting).count)",
                                    color: tracker.issues(.waiting).isEmpty ? .secondary : .orange) { go(.tasks, .waiting) }
                        Spacer()
                    }
                    let active = tracker.issues(.inProgress)
                    if active.isEmpty {
                        Text("Нет задач в работе").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    ForEach(active.prefix(4)) { issue in
                        CompactIssueRow(issue: issue, timerRunning: tracker.timer?.key == issue.key) { openIssue(issue) }
                    }
                }
            }
        }
    }

    // MARK: CI

    private var ciCard: some View {
        SectionCard(title: "CI/CD", systemImage: "arrow.triangle.branch") {
            Button("Все →") { go(.ci, nil) }.buttonStyle(.link).font(.caption)
        } content: {
            let highlights = state.ciHighlights
            if settings.projects.isEmpty {
                Text("Проекты не выбраны").font(.caption).foregroundStyle(.secondary)
            } else if highlights.isEmpty {
                Label("Все пайплайны зелёные · проектов: \(settings.projects.count)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(highlights.prefix(4), id: \.pipeline.id) { item in
                            HoverRow(action: { openURL(item.pipeline.webUrl) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: PipelineStyle.symbol(item.pipeline.status))
                                        .foregroundStyle(PipelineStyle.color(item.pipeline.status))
                                    Text(item.project.name).font(.callout.weight(.medium))
                                    Text(item.pipeline.ref).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if let d = item.pipeline.createdAt, PipelineStatus.isActive(item.pipeline.status) {
                                        Text(Fmt.duration(ctx.date.timeIntervalSince(d))).font(.caption).monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Claude

    private var claudeCard: some View {
        SectionCard(title: "Claude", systemImage: "sparkle") {
            Button("Подробнее →") { go(.claude, nil) }.buttonStyle(.link).font(.caption)
        } content: {
            if let usage = state.claudeUsage {
                VStack(spacing: 6) {
                    if let s = usage.session { MiniLimit(title: "5 ч", limit: s) }
                    if let w = usage.weekly { MiniLimit(title: "Неделя", limit: w) }
                }
            } else if let error = state.claudeError {
                ErrorLine(text: error)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

struct MiniLimit: View {
    let title: String
    let limit: ClaudeLimit

    private var color: Color { limit.percent >= 90 ? .red : limit.percent >= 70 ? .orange : .green }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            UsageBar(fraction: limit.percent / 100, color: color)
            Text("\(Int(limit.percent.rounded()))%").font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(color).frame(width: 36, alignment: .trailing)
            if let r = limit.resetsAt {
                Text(Fmt.duration(r.timeIntervalSinceNow)).font(.caption2).foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .trailing)
                    .help(Fmt.reset(r))
            }
        }
    }
}

struct CounterPill: View {
    let icon: String
    let text: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// Активный таймер: всегда первым в сводке.
struct TimerCard: View {
    @ObservedObject var tracker: TrackerStore
    let timer: TrackerTimer
    @State private var busy = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer").font(.title3).foregroundStyle(.blue)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(timer.summary).font(.callout).lineLimit(1)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Fmt.clock(ctx.date.timeIntervalSince(timer.startedAt)))
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            Button {
                busy = true
                Task { await tracker.stopTimer(log: true); busy = false }
            } label: {
                Image(systemName: "stop.fill")
            }
            .help("Остановить и списать время")
            .disabled(busy)
            Menu {
                Button("Сбросить без списания", role: .destructive) { Task { await tracker.stopTimer(log: false) } }
                Button("Открыть в трекере") { openURL("https://tracker.yandex.ru/\(timer.key)") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.1)))
    }
}
