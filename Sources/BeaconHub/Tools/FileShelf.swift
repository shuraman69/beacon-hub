import AppKit
import Combine
import QuickLookThumbnailing
import SwiftUI

/// Файл на полке: копия лежит в `~/Library/Application Support/BeaconHub/Shelf/<id>/<имя>`.
struct ShelfItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var name: String { url.lastPathComponent }
}

/// Полка для файлов: временное место, куда можно бросить файл и вытащить его в другом приложении.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    /// Сколько файлов ещё копируется.
    @Published private(set) var copying = 0
    /// Над полкой сейчас держат файл.
    @Published var isTargeted = false
    /// Для анимации появления содержимого: false в момент открытия, потом пружиной в true.
    @Published var presented = true

    let dir: URL
    /// Маркер в папке файла: файл уже вытащили, папку можно удалить при следующем запуске.
    private static let consumedMarker = ".consumed"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = ProcessInfo.processInfo.environment["BEACONHUB_SHELF_DIR"].map { URL(fileURLWithPath: $0) }
            ?? base.appendingPathComponent("BeaconHub/Shelf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        restore()
    }

    /// Копирует файлы на полку. На APFS это клон: мгновенно и без лишнего места на диске.
    func add(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.resolvingSymlinksInPath().path })
        for source in urls where !source.path.hasPrefix(dir.path) && !existing.contains(source.path) {
            let id = UUID()
            let folder = dir.appendingPathComponent(id.uuidString)
            let target = folder.appendingPathComponent(source.lastPathComponent)
            copying += 1
            Task.detached(priority: .userInitiated) {
                let ok: Bool
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: target)
                    ok = true
                } catch {
                    Log.info("Полка: не удалось скопировать \(source.lastPathComponent): \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: folder)
                    ok = false
                }
                await MainActor.run {
                    self.copying -= 1
                    if ok {
                        let item = ShelfItem(id: id, url: target)
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.66)) { self.items.append(item) }
                        self.loadThumbnail(item)
                    } else {
                        Toast.show("Не удалось положить на полку", subtitle: source.lastPathComponent, systemImage: "exclamationmark.triangle")
                    }
                }
            }
        }
    }

    /// Файл вытащили: убираем с полки сразу, а копию удаляем через 2 минуты.
    /// Приложение, куда его бросили, может читать файл не мгновенно (Telegram, браузер).
    func consume(_ ids: [UUID]) {
        let gone = items.filter { ids.contains($0.id) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { items.removeAll { ids.contains($0.id) } }
        for item in gone {
            thumbnails[item.id] = nil
            let folder = item.url.deletingLastPathComponent()
            FileManager.default.createFile(atPath: folder.appendingPathComponent(Self.consumedMarker).path, contents: nil)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Удалить с полки без вытаскивания.
    func remove(_ ids: [UUID]) {
        let gone = items.filter { ids.contains($0.id) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { items.removeAll { ids.contains($0.id) } }
        for item in gone {
            thumbnails[item.id] = nil
            try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
        }
    }

    func clear() { remove(items.map(\.id)) }

    private func restore() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var restored: [(ShelfItem, Date)] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            if files.contains(Self.consumedMarker) || files.isEmpty {
                try? fm.removeItem(at: folder)
                continue
            }
            guard let name = files.first(where: { !$0.hasPrefix(".") }) else { continue }
            let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            restored.append((ShelfItem(id: id, url: folder.appendingPathComponent(name)), date))
        }
        items = restored.sorted { $0.1 < $1.1 }.map(\.0)
        items.forEach(loadThumbnail)
    }

    private func loadThumbnail(_ item: ShelfItem) {
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: item.url.path)
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 96, height: 96),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.items.contains(where: { $0.id == item.id }) { self.thumbnails[item.id] = image }
                }
            }
        }
    }
}

// MARK: - Окно

/// Показывает полку под иконкой в статус-баре, когда начинают тащить файл.
@MainActor
final class ShelfController {
    let store: ShelfStore
    private let settings: AppSettings
    /// Рамка кнопки в статус-баре в координатах экрана. Задаёт StatusItemController.
    var anchor: (() -> NSRect?)?

    private var panel: NSPanel?
    private var hosting: NSHostingView<ShelfView>?
    private var dragMonitor: Any?
    private var lastDragChange = NSPasteboard(name: .drag).changeCount
    private var dragActive = false
    private var releaseTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(store: ShelfStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.storeChanged() } }
            .store(in: &cancellables)
    }

    private var hiding = false
    /// Счётчик анимаций: если полку снова открыли, пока она пряталась, старое скрытие не срабатывает.
    private var animationGen = 0

    var isVisible: Bool { panel?.isVisible == true && !hiding }

    func start() {
        guard dragMonitor == nil else { return }
        // Глобальный монитор мыши не требует «Универсального доступа» (в отличие от клавиатуры).
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
    }

    func stop() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        hide()
    }

    func toggle() { isVisible ? hide() : show() }

    /// Появление: выезжает из-под статус-бара вниз, проявляется, содержимое «распрямляется» пружиной.
    func show() {
        let panel = self.panel ?? makePanel()
        if isVisible { resize(); return }
        animationGen += 1
        let target = targetFrame()
        if !hiding || !panel.isVisible {
            panel.setFrame(target.offsetBy(dx: 0, dy: 16), display: false)
            panel.alphaValue = 0
        }
        hiding = false
        store.presented = false
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { self.store.presented = true }
        }
    }

    /// Исчезновение: короткий подъём вверх с затуханием.
    func hide() {
        store.isTargeted = false
        guard let panel, panel.isVisible, !hiding else { return }
        hiding = true
        animationGen += 1
        let gen = animationGen
        withAnimation(.easeIn(duration: 0.16)) { store.presented = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 12), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard gen == self.animationGen else { return }
                panel.orderOut(nil)
                self.hiding = false
            }
        })
    }

    // MARK: Отслеживание перетаскивания

    private func mouseDragged() {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != lastDragChange || dragActive else { return }
        // Только файлы: перетаскивание текста, вкладок и окон полку не открывает.
        guard pb.types?.contains(.fileURL) == true else { lastDragChange = pb.changeCount; return }
        if settings.shelfTrigger == .nearTop && !cursorNearTop() { return }
        lastDragChange = pb.changeCount
        guard !dragActive else { return }
        dragActive = true
        show()
        watchRelease()
    }

    private func cursorNearTop() -> Bool {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return false }
        return p.y > screen.frame.maxY - 120
    }

    /// Во время перетаскивания отпускание кнопки не всегда доходит до глобального монитора, поэтому опрашиваем.
    private func watchRelease() {
        releaseTimer?.invalidate()
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    timer.invalidate()
                    self.dragActive = false
                    // Даём время принять бросок и начать копирование.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.hideIfEmpty() }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        releaseTimer = t
    }

    private func hideIfEmpty() {
        if store.items.isEmpty && store.copying == 0 && !dragActive { hide() }
    }

    private func storeChanged() {
        guard isVisible else { return }
        resize()
        if store.items.isEmpty && store.copying == 0 && !dragActive && !store.isTargeted { hide() }
    }

    // MARK: Панель

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 230, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let drop = ShelfDropView(store: store)
        drop.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(drop)

        let host = NSHostingView(rootView: ShelfView(store: store, close: { [weak self] in self?.hide() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(host)
        NSLayoutConstraint.activate([
            drop.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            drop.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            drop.topAnchor.constraint(equalTo: effect.topAnchor),
            drop.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
            host.topAnchor.constraint(equalTo: drop.topAnchor),
            host.bottomAnchor.constraint(equalTo: drop.bottomAnchor),
        ])
        panel.contentView = effect
        self.panel = panel
        self.hosting = host
        return panel
    }

    /// Размер по содержимому, верх прижат к низу статус-бара под иконкой.
    /// Плавно подгоняет размер под содержимое (добавили или забрали файлы).
    private func resize() {
        guard let panel else { return }
        let target = targetFrame()
        guard target != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func targetFrame() -> NSRect {
        guard let hosting else { return .zero }
        let size = hosting.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let anchorRect = anchor?() ?? NSRect(x: screen.frame.maxX - 300, y: screen.visibleFrame.maxY, width: 30, height: 0)
        let target = NSScreen.screens.first { $0.frame.contains(anchorRect.origin) } ?? screen
        var x = anchorRect.midX - size.width / 2
        x = min(max(x, target.frame.minX + 8), target.frame.maxX - size.width - 8)
        let top = anchorRect.minY - 6
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}

enum ShelfTrigger: String, CaseIterable, Identifiable {
    case anyDrag, nearTop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .anyDrag: return "При любом перетаскивании файла"
        case .nearTop: return "Только у верхнего края экрана"
        }
    }
}

// MARK: - Приём файлов

/// Принимает брошенные файлы. Свои же файлы, вытащенные с полки и брошенные обратно, игнорирует.
final class ShelfDropView: NSView {
    private let store: ShelfStore

    init(store: ShelfStore) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        !(sender.draggingSource is ShelfDragSourceView)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        MainActor.assumeIsolated { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { store.isTargeted = true } }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.isTargeted = false } }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        MainActor.assumeIsolated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { store.isTargeted = false }
            store.add(urls)
        }
        return !urls.isEmpty
    }
}

// MARK: - Вытаскивание файлов

/// Прозрачный слой поверх миниатюры: из него тащат файл (или все файлы) наружу. Двойной клик открывает файл.
final class ShelfDragSourceView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onEnded: (NSDragOperation) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    private var downEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        if event.clickCount == 2 { onDoubleClick() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        downEvent = nil
        let point = convert(down.locationInWindow, from: nil)
        let files = urls()
        let items = files.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            let offset = CGFloat(index) * 6
            item.setDraggingFrame(NSRect(x: point.x - 24 + offset, y: point.y - 24 - offset, width: 48, height: 48),
                                  contents: icon)
            return item
        }
        guard !items.isEmpty else { return }
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnded(operation)
    }
}

struct ShelfDragSource: NSViewRepresentable {
    let urls: () -> [URL]
    let onEnded: (NSDragOperation) -> Void
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> ShelfDragSourceView { ShelfDragSourceView() }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        view.urls = urls
        view.onEnded = onEnded
        view.onDoubleClick = onDoubleClick
    }
}

// MARK: - Вёрстка

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    let close: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(64), spacing: 8), count: 3)
    @State private var dashPhase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.items.isEmpty {
                dropZone(big: true)
            } else {
                header
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(store.items) {
                            ShelfTile(store: store, item: $0)
                                .transition(.asymmetric(insertion: .scale(scale: 0.4).combined(with: .opacity),
                                                        removal: .scale(scale: 0.6).combined(with: .opacity)))
                        }
                    }
                }
                .frame(height: gridHeight)
                if store.isTargeted || store.copying > 0 {
                    dropZone(big: false).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .padding(10)
        .frame(width: 236)
        .scaleEffect(store.presented ? 1 : 0.88, anchor: .top)
        .opacity(store.presented ? 1 : 0)
        .blur(radius: store.presented ? 0 : 4)
    }

    private var gridHeight: CGFloat {
        let rows = min(3, (store.items.count + 2) / 3)
        return CGFloat(rows) * 86 + CGFloat(max(rows - 1, 0)) * 8
    }

    private var header: some View {
        HStack(spacing: 6) {
            // За заголовок можно утащить сразу все файлы.
            HStack(spacing: 4) {
                Image(systemName: "tray.full")
                Text(store.items.count == 1 ? "1 файл" : "Файлов: \(store.items.count)")
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            .overlay(ShelfDragSource(urls: { store.items.map(\.url) }, onEnded: { op in
                if !op.isEmpty { store.consume(store.items.map(\.id)) }
            }))
            .help("Перетащи, чтобы забрать все файлы")
            Spacer()
            Button { store.clear() } label: { Image(systemName: "trash") }
                .help("Очистить полку")
            Button(action: close) { Image(systemName: "xmark") }
                .help("Скрыть (файлы останутся на полке)")
        }
        .buttonStyle(.borderless)
    }

    private func dropZone(big: Bool) -> some View {
        VStack(spacing: 4) {
            if store.copying > 0 {
                ProgressView().controlSize(.small)
                Text("Копирую…").font(.caption)
            } else {
                Image(systemName: store.isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                    .font(big ? .title2 : .body)
                    .symbolEffect(.bounce, value: store.isTargeted)
                    .offset(y: store.isTargeted ? 2 : 0)
                Text(big ? "Положи сюда" : "Добавить").font(big ? .callout.weight(.medium) : .caption)
            }
        }
        .foregroundStyle(store.isTargeted ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity)
        .frame(height: big ? 90 : 44)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: store.isTargeted ? 2 : 1.5, dash: [5, 4], dashPhase: dashPhase))
                .foregroundStyle(store.isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .background(RoundedRectangle(cornerRadius: 10).fill(store.isTargeted ? Color.accentColor.opacity(0.14) : .clear))
        .scaleEffect(store.isTargeted ? 1.04 : 1)
        // «Бегущий» пунктир: зона приёма выглядит живой.
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { dashPhase = -18 }
        }
    }
}

struct ShelfTile: View {
    @ObservedObject var store: ShelfStore
    let item: ShelfItem
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let image = store.thumbnails[item.id] {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc").font(.title)
                }
            }
            .frame(width: 56, height: 56)
            Text(item.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(height: 24, alignment: .top)
        }
        .frame(width: 64, height: 86)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
        .overlay(ShelfDragSource(urls: { [item.url] }, onEnded: { op in
            if !op.isEmpty { store.consume([item.id]) }
        }, onDoubleClick: { NSWorkspace.shared.open(item.url) }))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { store.remove([item.id]) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Убрать с полки")
            }
        }
        .onHover { hovering = $0 }
        .help("\(item.name)\nПеретащи, чтобы забрать. Двойной клик открывает.")
    }
}
