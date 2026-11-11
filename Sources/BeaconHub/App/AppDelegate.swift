import AppKit
import SwiftUI

@main
enum BeaconHubMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // без иконки в Dock
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private lazy var state = AppState(settings: settings)
    private lazy var tools = ToolsController(settings: settings)
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?

    func applicationWillTerminate(_ notification: Notification) {
        state.notes.flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Notifier.shared.setup()
        statusItem = StatusItemController(state: state, settings: settings, tools: tools, openSettings: { [weak self] in
            self?.showSettings()
        })
        state.start()
        tools.start()

        if let dir = ProcessInfo.processInfo.environment["BEACONHUB_SNAPSHOT_DIR"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                await self.renderSnapshots(to: dir)
            }
            return
        }

        // Первый запуск: сразу открываем настройки, чтобы выбрать проекты.
        if settings.projects.isEmpty && !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            showSettings()
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(state: state, settings: settings, tools: tools))
            let window = NSWindow(contentViewController: host)
            window.title = "Beacon Hub: настройки"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Отладка: рисует панель по каждой вкладке в PNG и завершает работу (`BEACONHUB_SNAPSHOT_DIR=… BeaconHub`).
    private func renderSnapshots(to dir: String) async {
        let previousTab = settings.panelTab
        for tab in PanelTab.allCases {
            settings.panelTab = tab.rawValue
            let view = PanelView(state: state, settings: settings, openSettings: {}, runTool: { _ in })
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 390, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 600_000_000)
            let size = host.fittingSize
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel-\(tab.rawValue).png"))
            }
            window.orderOut(nil)
        }
        let snapshotKey = ProcessInfo.processInfo.environment["BEACONHUB_SNAPSHOT_ISSUE"]
            ?? state.tracker.issues(.inProgress).first?.key
        if let issueKey = snapshotKey {
            let detail = IssueDetailView(tracker: state.tracker, issueKey: issueKey, back: {})
                .padding(12).frame(width: 390).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: detail)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.alphaValue = 0.01 // окно «видимо» для системы, иначе SwiftUI не запускает .task
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 6_000_000_000) // переходы и комментарии
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel-detail.png"))
            }
            window.orderOut(nil)
        }
        if let note = state.notes.sorted.first {
            let detail = NoteDetailView(store: state.notes, tracker: state.tracker, id: note.id, focusItems: false, back: {})
                .padding(12).frame(width: 390).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: detail)
            let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 390, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 600_000_000)
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel-note.png"))
            }
            window.orderOut(nil)
        }
        settings.panelTab = previousTab
        NSApp.terminate(nil)
    }

    /// У accessory-приложений нет меню. Без меню Edit в полях не работают ⌘C/⌘V/⌘A.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Выйти из Beacon Hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
