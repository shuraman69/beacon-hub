import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

enum MenuBarPercent: String, CaseIterable, Identifiable {
    case none, session, weekly, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Только иконка"
        case .session: return "Сессия (5 ч)"
        case .weekly: return "Неделя"
        case .both: return "Сессия и неделя"
        }
    }
}

/// Пользовательские настройки (UserDefaults). Секреты здесь не хранятся, только в Keychain.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var projects: [ProjectRef] { didSet { saveJSON(projects, "projects") } }
    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var pipelinesPerProject: Int { didSet { defaults.set(pipelinesPerProject, forKey: "pipelinesPerProject") } }
    @Published var onlyMyPipelines: Bool { didSet { defaults.set(onlyMyPipelines, forKey: "onlyMyPipelines") } }
    @Published var menuBarPercent: MenuBarPercent { didSet { defaults.set(menuBarPercent.rawValue, forKey: "menuBarPercent") } }
    @Published var notifyFailed: Bool { didSet { defaults.set(notifyFailed, forKey: "notifyFailed") } }
    @Published var notifySuccess: Bool { didSet { defaults.set(notifySuccess, forKey: "notifySuccess") } }
    @Published var showClaude: Bool { didSet { defaults.set(showClaude, forKey: "showClaude") } }
    @Published var showGitLab: Bool { didSet { defaults.set(showGitLab, forKey: "showGitLab") } }
    @Published var showNotes: Bool { didSet { defaults.set(showNotes, forKey: "showNotes") } }

    // Текст с экрана
    @Published var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: "ocrEnabled") } }
    @Published var ocrShortcut: Shortcut? { didSet { saveShortcut(ocrShortcut, "ocrShortcut") } }
    @Published var ocrJoinLines: Bool { didSet { defaults.set(ocrJoinLines, forKey: "ocrJoinLines") } }

    // История буфера
    @Published var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var clipboardShortcut: Shortcut? { didSet { saveShortcut(clipboardShortcut, "clipboardShortcut") } }
    @Published var clipboardMaxItems: Int { didSet { defaults.set(clipboardMaxItems, forKey: "clipboardMaxItems") } }
    @Published var clipboardPasteDirectly: Bool { didSet { defaults.set(clipboardPasteDirectly, forKey: "clipboardPasteDirectly") } }
    @Published var clipboardSaveImages: Bool { didSet { defaults.set(clipboardSaveImages, forKey: "clipboardSaveImages") } }
    @Published var shelfEnabled: Bool { didSet { defaults.set(shelfEnabled, forKey: "shelfEnabled") } }
    @Published var shelfTrigger: ShelfTrigger { didSet { defaults.set(shelfTrigger.rawValue, forKey: "shelfTrigger") } }

    // Яндекс Трекер
    @Published var trackerEnabled: Bool { didSet { defaults.set(trackerEnabled, forKey: "trackerEnabled") } }
    @Published var trackerOrgId: String { didSet { defaults.set(trackerOrgId, forKey: "trackerOrgId") } }
    @Published var trackerOrgIsCloud: Bool { didSet { defaults.set(trackerOrgIsCloud, forKey: "trackerOrgIsCloud") } }
    @Published var trackerNotifyAssigned: Bool { didSet { defaults.set(trackerNotifyAssigned, forKey: "trackerNotifyAssigned") } }
    @Published var trackerNotifyMention: Bool { didSet { defaults.set(trackerNotifyMention, forKey: "trackerNotifyMention") } }
    @Published var trackerNotifyComment: Bool { didSet { defaults.set(trackerNotifyComment, forKey: "trackerNotifyComment") } }
    @Published var trackerNotifyStatus: Bool { didSet { defaults.set(trackerNotifyStatus, forKey: "trackerNotifyStatus") } }

    @Published var trackerBranchTemplate: String { didSet { defaults.set(trackerBranchTemplate, forKey: "trackerBranchTemplate") } }

    @Published var trackerStatusKeys: [String] { didSet { defaults.set(trackerStatusKeys, forKey: "trackerStatusKeys") } }

    /// Последняя открытая вкладка панели.
    @Published var panelTab: String { didSet { defaults.set(panelTab, forKey: "panelTab") } }

    private init() {
        let d = UserDefaults.standard
        projects = (d.data(forKey: "projects")).flatMap { try? JSONDecoder().decode([ProjectRef].self, from: $0) } ?? []
        refreshInterval = d.object(forKey: "refreshInterval") as? Double ?? 60
        pipelinesPerProject = d.object(forKey: "pipelinesPerProject") as? Int ?? 3
        onlyMyPipelines = d.object(forKey: "onlyMyPipelines") as? Bool ?? false
        menuBarPercent = MenuBarPercent(rawValue: d.string(forKey: "menuBarPercent") ?? "") ?? .session
        notifyFailed = d.object(forKey: "notifyFailed") as? Bool ?? true
        notifySuccess = d.object(forKey: "notifySuccess") as? Bool ?? false
        showClaude = d.object(forKey: "showClaude") as? Bool ?? true
        showGitLab = d.object(forKey: "showGitLab") as? Bool ?? true
        showNotes = d.object(forKey: "showNotes") as? Bool ?? true

        ocrEnabled = d.object(forKey: "ocrEnabled") as? Bool ?? true
        ocrShortcut = Self.loadShortcut(d, "ocrShortcut", default: .textCaptureDefault)
        ocrJoinLines = d.object(forKey: "ocrJoinLines") as? Bool ?? false
        clipboardEnabled = d.object(forKey: "clipboardEnabled") as? Bool ?? true
        clipboardShortcut = Self.loadShortcut(d, "clipboardShortcut", default: .clipboardDefault)
        clipboardMaxItems = d.object(forKey: "clipboardMaxItems") as? Int ?? 200
        clipboardPasteDirectly = d.object(forKey: "clipboardPasteDirectly") as? Bool ?? true
        clipboardSaveImages = d.object(forKey: "clipboardSaveImages") as? Bool ?? true
        shelfEnabled = d.object(forKey: "shelfEnabled") as? Bool ?? true
        shelfTrigger = ShelfTrigger(rawValue: d.string(forKey: "shelfTrigger") ?? "") ?? .anyDrag

        trackerEnabled = d.object(forKey: "trackerEnabled") as? Bool ?? true
        trackerOrgId = d.string(forKey: "trackerOrgId") ?? ""
        trackerOrgIsCloud = d.object(forKey: "trackerOrgIsCloud") as? Bool ?? true
        trackerNotifyAssigned = d.object(forKey: "trackerNotifyAssigned") as? Bool ?? true
        trackerNotifyMention = d.object(forKey: "trackerNotifyMention") as? Bool ?? true
        trackerNotifyComment = d.object(forKey: "trackerNotifyComment") as? Bool ?? true
        trackerNotifyStatus = d.object(forKey: "trackerNotifyStatus") as? Bool ?? true
        panelTab = d.string(forKey: "panelTab") ?? "summary"
        trackerBranchTemplate = d.string(forKey: "trackerBranchTemplate") ?? "{key}-{slug}"
        trackerStatusKeys = d.stringArray(forKey: "trackerStatusKeys") ?? TaskFilter.defaultStatusKeys
    }

    /// Ключа нет: значение по умолчанию. Пустые данные: пользователь сбросил сочетание.
    private static func loadShortcut(_ d: UserDefaults, _ key: String, default value: Shortcut) -> Shortcut? {
        guard let data = d.data(forKey: key) else { return value }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? value
    }

    private func saveShortcut(_ shortcut: Shortcut?, _ key: String) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
    }

    func toggleProject(_ ref: ProjectRef) {
        if let i = projects.firstIndex(where: { $0.id == ref.id }) {
            projects.remove(at: i)
        } else {
            projects.append(ref)
        }
    }

    private func saveJSON<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
