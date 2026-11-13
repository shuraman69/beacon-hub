import AppKit
import Combine
import SwiftUI

struct ToolsSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var tools: ToolsController
    @ObservedObject var store: ClipboardStore
    @ObservedObject private var shelf = ShelfStore.shared

    @State private var screenAccess = CGPreflightScreenCaptureAccess()
    @State private var axAccess = AXIsProcessTrusted()
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Включено", isOn: $settings.ocrEnabled)
                LabeledContent("Горячая клавиша") {
                    ShortcutRecorder(shortcut: $settings.ocrShortcut, defaultValue: .textCaptureDefault)
                }
                if let error = tools.hotKeyErrors[.textCapture] { ErrorLine(text: error) }
                Toggle("Склеивать строки в одну", isOn: $settings.ocrJoinLines)
                PermissionRow(title: "Запись экрана", granted: screenAccess,
                              settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    CGRequestScreenCaptureAccess()
                }
                Button("Попробовать сейчас") { tools.captureText() }
                    .disabled(!settings.ocrEnabled)
            } header: {
                Text("Текст с экрана")
            } footer: {
                Text("Выдели область: распознанный текст (русский и английский) или содержимое QR-кода сразу попадёт в буфер. Всё работает локально, без интернета.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Включено", isOn: $settings.clipboardEnabled)
                LabeledContent("Горячая клавиша") {
                    ShortcutRecorder(shortcut: $settings.clipboardShortcut, defaultValue: .clipboardDefault)
                }
                if let error = tools.hotKeyErrors[.clipboard] { ErrorLine(text: error) }
                Picker("Хранить элементов", selection: $settings.clipboardMaxItems) {
                    ForEach([50, 100, 200, 500, 1000], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Сохранять изображения", isOn: $settings.clipboardSaveImages)
                Toggle("Вставлять сразу в активное поле", isOn: $settings.clipboardPasteDirectly)
                if settings.clipboardPasteDirectly {
                    PermissionRow(title: "Универсальный доступ", granted: axAccess,
                                  settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        AXIsProcessTrustedWithOptions(options)
                    }
                }
                HStack {
                    Text("В истории: \(store.items.count), закреплено: \(store.items.filter(\.pinned).count)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Открыть") { tools.toggleClipboard() }
                        .disabled(!settings.clipboardEnabled)
                    Button("Очистить", role: .destructive) { store.clear(keepPinned: true) }
                }
            } header: {
                Text("История буфера обмена")
            } footer: {
                Text("Пароли из менеджеров паролей и «Связки ключей» не сохраняются. История лежит локально в ~/Library/Application Support/BeaconHub/Clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Включено", isOn: $settings.shelfEnabled)
                Picker("Показывать полку", selection: $settings.shelfTrigger) {
                    ForEach(ShelfTrigger.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Text("На полке: \(shelf.items.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Открыть") { tools.toggleShelf() }.disabled(!settings.shelfEnabled)
                    Button("Очистить", role: .destructive) { shelf.clear() }.disabled(shelf.items.isEmpty)
                }
            } header: {
                Text("Полка для файлов")
            } footer: {
                Text("Начни тащить файл, и под маяком появится полка. Брось файл туда, и на полке появится его копия. Вытащи файл с полки в любое приложение, и копия удалится. Разрешения macOS не нужны.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(permissionTimer) { _ in
            screenAccess = CGPreflightScreenCaptureAccess()
            axAccess = AXIsProcessTrusted()
        }
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let settingsURL: String
    let request: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(granted ? "\(title): разрешено" : "\(title): нет доступа")
            Spacer()
            if !granted {
                Button("Запросить", action: request)
                Button("Открыть настройки") { openURL(settingsURL) }
            }
        }
    }
}

/// Кнопка записи сочетания клавиш: нажал, затем нажал нужное сочетание. Esc отменяет запись.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    let defaultValue: Shortcut

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Нажми сочетание…" : (shortcut?.display ?? "Не задано"))
                    .frame(minWidth: 120)
                    .monospaced()
            }
            .tint(recording ? .accentColor : nil)
            if shortcut != nil && !recording {
                Button {
                    shortcut = nil
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Сбросить")
            }
            if shortcut != defaultValue && !recording {
                Button("По умолчанию") { shortcut = defaultValue }
                    .buttonStyle(.link)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            if let s = Shortcut(event: event) {
                shortcut = s
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        HotKeyCenter.shared.suspended = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
