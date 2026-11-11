import AppKit
import Combine
import SwiftUI

/// Кнопка в статус-баре и всплывающая панель под ней.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let state: AppState
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []
    private var ticker: Timer?

    init(state: AppState, settings: AppSettings, tools: ToolsController, openSettings: @escaping () -> Void) {
        self.state = state
        self.settings = settings
        super.init()

        popover.behavior = .transient
        popover.animates = true
        let panel = PanelView(state: state, settings: settings, openSettings: { [weak self] in
            self?.popover.performClose(nil)
            openSettings()
        }, runTool: { [weak self] action in
            // Сначала закрываем панель, чтобы она не попала в снимок и не перехватывала фокус.
            self?.popover.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                switch action {
                case .captureText: tools.captureText()
                case .clipboard: tools.toggleClipboard()
                }
            }
        })
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageLeading
        }

        state.objectWillChange.merge(with: settings.objectWillChange, state.tracker.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange приходит до изменения, поэтому откладываем на следующий тик.
                DispatchQueue.main.async { self?.updateButton() }
            }
            .store(in: &cancellables)
        updateButton()

        // Пока идёт таймер, время в статус-баре обновляется раз в 30 с.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.state.tracker.timer != nil { self?.updateButton() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            state.refreshIfStale()
        }
    }

    private func updateButton() {
        guard let button = item.button else { return }

        let (symbol, color): (String, NSColor?) = {
            switch state.overallStatus {
            case .failed: return ("light.beacon.max.fill", .systemRed)
            case .running: return ("light.beacon.max", .systemBlue)
            case .ok, .unknown: return ("light.beacon.min", nil)
            }
        }()
        button.image = Self.symbolImage(symbol, color: color)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        func append(_ text: String, color: NSColor? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 0.5]
            if let color { attrs[.foregroundColor] = color }
            title.append(NSAttributedString(string: " " + text, attributes: attrs))
        }
        if let timer = state.tracker.timer {
            let minutes = Int(Date().timeIntervalSince(timer.startedAt) / 60)
            append(String(format: "⏱%d:%02d", minutes / 60, minutes % 60))
        }
        let percent = menuBarTitle()
        if !percent.isEmpty { append(percent) }
        let unread = state.tracker.unreadCount
        if unread > 0 { append("●\(unread)", color: .systemRed) }
        button.attributedTitle = title
        button.toolTip = "Beacon Hub"
    }

    private func menuBarTitle() -> String {
        guard settings.showClaude, let usage = state.claudeUsage else { return "" }
        let s = usage.session.map { "\(Int($0.percent.rounded()))%" }
        let w = usage.weekly.map { "\(Int($0.percent.rounded()))%" }
        switch settings.menuBarPercent {
        case .none: return ""
        case .session: return s ?? ""
        case .weekly: return w ?? ""
        case .both: return [s, w].compactMap { $0 }.joined(separator: " · ")
        }
    }

    static func symbolImage(_ name: String, color: NSColor?) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: "Beacon Hub")
            ?? NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Beacon Hub"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = color == nil
        return image
    }
}
