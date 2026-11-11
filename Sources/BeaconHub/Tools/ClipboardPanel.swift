import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Всплывающая панель истории буфера (как в Spotlight): не активирует приложение,
/// поэтому после выбора вставка уходит в то окно, где ты работал.
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private let store: ClipboardStore
    private let settings: AppSettings
    private let model: ClipboardPanelModel
    private lazy var panel: KeyablePanel = makePanel()
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    init(store: ClipboardStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.model = ClipboardPanelModel(store: store)
        super.init()
        model.onChoose = { [weak self] item in self?.choose(item) }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }

        model.reset()
        positionNearMouse()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func choose(_ item: ClipboardItem) {
        hide()
        store.copyToPasteboard(item)

        guard settings.clipboardPasteDirectly else {
            Toast.show("Скопировано", subtitle: preview(item), systemImage: "doc.on.clipboard")
            return
        }
        guard AXIsProcessTrusted() else {
            // Один раз спросим разрешение, а пока просто скопируем.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            Toast.show("Скопировано: вставь ⌘V",
                       subtitle: "Чтобы вставлять сразу, разреши Beacon Hub в «Универсальном доступе»",
                       systemImage: "doc.on.clipboard", color: .orange, duration: 4)
            return
        }
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.postCommandV()
        }
    }

    private func preview(_ item: ClipboardItem) -> String {
        switch item.kind {
        case .text: return item.text ?? ""
        case .image: return "Изображение"
        case .files: return (item.files ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }

    static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Клавиатура

    private static let digitKeys: [UInt16: Int] = [
        UInt16(kVK_ANSI_1): 0, UInt16(kVK_ANSI_2): 1, UInt16(kVK_ANSI_3): 2, UInt16(kVK_ANSI_4): 3,
        UInt16(kVK_ANSI_5): 4, UInt16(kVK_ANSI_6): 5, UInt16(kVK_ANSI_7): 6, UInt16(kVK_ANSI_8): 7, UInt16(kVK_ANSI_9): 8,
    ]

    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let cmd = event.modifierFlags.contains(.command)
            switch Int(event.keyCode) {
            case kVK_DownArrow: model.moveSelection(1); return nil
            case kVK_UpArrow: model.moveSelection(-1); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter: model.chooseSelected(); return nil
            case kVK_Escape: hide(); return nil
            case kVK_Delete where cmd: model.deleteSelected(); return nil
            case kVK_ANSI_P where cmd: model.pinSelected(); return nil
            default:
                if cmd, let index = Self.digitKeys[event.keyCode] {
                    model.choose(at: index)
                    return nil
                }
                return event
            }
        }
    }

    // MARK: - Окно

    private func makePanel() -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: true)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        p.contentView = NSHostingView(rootView: ClipboardPanelView(model: model))
        return p
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        if origin.y < visible.minY + 8 { origin.y = min(mouse.y + 12, visible.maxY - size.height - 8) }
        panel.setFrameOrigin(origin)
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Модель

@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var focusToken = 0

    let store: ClipboardStore
    var onChoose: ((ClipboardItem) -> Void)?
    private var cancellable: AnyCancellable?

    init(store: ClipboardStore) {
        self.store = store
        cancellable = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Закреплённые сверху, остальные по времени. Фильтр по подстроке без учёта регистра.
    var visible: [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? store.items : store.items.filter { $0.searchable.localizedCaseInsensitiveContains(q) }
        return filtered.filter(\.pinned) + filtered.filter { !$0.pinned }
    }

    func reset() {
        query = ""
        selection = 0
        focusToken += 1
    }

    func moveSelection(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func choose(at index: Int) {
        let items = visible
        guard items.indices.contains(index) else { return }
        onChoose?(items[index])
    }

    func chooseSelected() { choose(at: selection) }

    func deleteSelected() {
        let items = visible
        guard items.indices.contains(selection) else { return }
        store.delete(items[selection])
        selection = min(selection, max(visible.count - 1, 0))
    }

    func pinSelected() {
        let items = visible
        guard items.indices.contains(selection) else { return }
        store.togglePin(items[selection])
    }
}

// MARK: - UI

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.visible
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск в истории буфера", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                Text("\(items.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "История пуста: скопируй что-нибудь" : "Ничего не найдено")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipboardRow(item: item, index: index, selected: index == model.selection,
                                             imageURL: model.store.imageURL(for: item))
                                    .id(item.id)
                                    .onTapGesture { model.choose(at: index) }
                                    .onHover { if $0 { model.selection = index } }
                                    .contextMenu {
                                        Button(item.pinned ? "Открепить" : "Закрепить") { model.store.togglePin(item) }
                                        Button("Удалить", role: .destructive) { model.store.delete(item) }
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selection) { _, new in
                        if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                hint("↩", "вставить")
                hint("⌘1–9", "быстро")
                hint("⌘P", "закрепить")
                hint("⌘⌫", "удалить")
                Spacer()
                hint("esc", "закрыть")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 460, height: 500)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { searchFocused = true }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ClipboardRow: View {
    let item: ClipboardItem
    let index: Int
    let selected: Bool
    let imageURL: URL?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AppIconView(bundleID: item.appBundleID, kind: item.kind)
            content
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    if item.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    if index < 9 { Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary) }
                }
                Text(Fmt.relative(item.date)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            Text((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            if let imageURL, let image = ImageCache.shared.image(for: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 64, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Изображение").foregroundStyle(.secondary)
            }
        case .files:
            VStack(alignment: .leading, spacing: 1) {
                ForEach((item.files ?? []).prefix(3), id: \.self) { path in
                    Label((path as NSString).lastPathComponent, systemImage: "doc")
                        .font(.callout)
                        .lineLimit(1)
                }
                if let files = item.files, files.count > 3 {
                    Text("и ещё \(files.count - 3)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AppIconView: View {
    let bundleID: String?
    let kind: ClipboardItem.Kind

    var body: some View {
        Group {
            if let bundleID, let icon = ImageCache.shared.appIcon(bundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: kind == .image ? "photo" : kind == .files ? "doc.on.doc" : "text.alignleft")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let images = NSCache<NSURL, NSImage>()
    private var icons: [String: NSImage?] = [:]

    func image(for url: URL) -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: url as NSURL)
        return image
    }

    func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = icon
        return icon
    }
}
