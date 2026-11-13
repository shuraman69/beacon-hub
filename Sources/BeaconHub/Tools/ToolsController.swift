import AppKit
import Combine

/// Инструменты, которые вызываются горячими клавишами: текст с экрана и история буфера.
@MainActor
final class ToolsController: ObservableObject {
    enum HotKeyID: UInt32 { case textCapture = 1, clipboard = 2 }

    let settings: AppSettings
    let textCapture: TextCapture
    let clipboardStore: ClipboardStore
    let clipboardPanel: ClipboardPanelController
    let shelf: ShelfController

    /// Ошибки регистрации горячих клавиш (обычно сочетание уже занято другим приложением).
    @Published private(set) var hotKeyErrors: [HotKeyID: String] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings) {
        self.settings = settings
        textCapture = TextCapture(settings: settings)
        clipboardStore = ClipboardStore(settings: settings)
        clipboardPanel = ClipboardPanelController(store: clipboardStore, settings: settings)
        shelf = ShelfController(store: .shared, settings: settings)
    }

    func start() {
        apply()
        // Любое изменение настроек инструментов приводит к перерегистрации хоткеев и мониторинга.
        Publishers.MergeMany(
            settings.$ocrEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$ocrShortcut.map { _ in () }.eraseToAnyPublisher(),
            settings.$clipboardEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$clipboardShortcut.map { _ in () }.eraseToAnyPublisher(),
            settings.$shelfEnabled.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(5)
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.apply() }
        .store(in: &cancellables)

        settings.$clipboardMaxItems.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.clipboardStore.trim() }
            .store(in: &cancellables)
    }

    func captureText() {
        guard settings.ocrEnabled else { return }
        textCapture.start()
    }

    func toggleShelf() {
        shelf.toggle()
    }

    func toggleClipboard() {
        guard settings.clipboardEnabled else { return }
        clipboardPanel.toggle()
    }

    private func apply() {
        register(.textCapture, enabled: settings.ocrEnabled, shortcut: settings.ocrShortcut) { [weak self] in
            self?.captureText()
        }
        register(.clipboard, enabled: settings.clipboardEnabled, shortcut: settings.clipboardShortcut) { [weak self] in
            self?.toggleClipboard()
        }
        if settings.ocrEnabled { textCapture.warmUp() }
        if settings.shelfEnabled { shelf.start() } else { shelf.stop() }
        if settings.clipboardEnabled {
            clipboardStore.start()
        } else {
            clipboardStore.stop()
            clipboardPanel.hide()
        }
    }

    private func register(_ id: HotKeyID, enabled: Bool, shortcut: Shortcut?, action: @escaping () -> Void) {
        HotKeyCenter.shared.unregister(id: id.rawValue)
        hotKeyErrors[id] = nil
        guard enabled, let shortcut else { return }
        if !HotKeyCenter.shared.register(id: id.rawValue, shortcut: shortcut, handler: action) {
            hotKeyErrors[id] = "\(shortcut.display) уже занято другим приложением (TextSniper, CopyClip?). Закрой его или выбери другое сочетание."
        }
    }
}
