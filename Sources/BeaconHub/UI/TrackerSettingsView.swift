import AppKit
import SwiftUI

struct TrackerSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var tracker: TrackerStore

    @State private var tokenInput = ""
    @State private var checking = false
    @State private var status: (text: String, ok: Bool)?
    @State private var allStatuses: [TrackerAPI.TStatus] = []

    private var mcpCommand: String {
        "TRACKER_TOKEN=$(security find-generic-password -s \(TrackerAuth.keychainService) -w) "
            + "\(settings.trackerOrgIsCloud ? "TRACKER_CLOUD_ORG_ID" : "TRACKER_ORG_ID")=\(settings.trackerOrgId) "
            + "TRACKER_READ_ONLY=false exec uvx yandex-tracker-mcp@latest"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Показывать трекер", isOn: $settings.trackerEnabled)
                HStack {
                    if let me = tracker.me {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Подключено: \(me.display) (\(me.login))")
                    } else if let error = tracker.error {
                        ErrorLine(text: error)
                    } else {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        Text("Не подключено").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                TextField("ID организации", text: $settings.trackerOrgId, prompt: Text("bpf… или 1234567"))
                Toggle("Облачная организация (Yandex Cloud)", isOn: $settings.trackerOrgIsCloud)
                Text("ID есть в трекере: Администрирование → Организации. Облачные начинаются с букв (bpf…), у Яндекс 360 ID числовой.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Подключение")
            }

            Section {
                HStack {
                    Button("1. Получить токен в Яндексе ↗") { openURL(TrackerAuth.authorizeURL) }
                    Spacer()
                }
                HStack {
                    SecureField("2. Вставь токен (y0_…)", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                    Button("3. Проверить и сохранить", action: saveToken)
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty || checking
                                  || settings.trackerOrgId.isEmpty)
                }
                if checking { ProgressView().controlSize(.small) }
                if let status {
                    if status.ok {
                        Label(status.text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        ErrorLine(text: status.text)
                    }
                }
                Text("Токен живёт около года и хранится в Keychain (`\(TrackerAuth.keychainService)`). Его же может использовать MCP трекера в Claude Code, см. ниже.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Токен")
            }

            Section {
                if allStatuses.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Загружаю статусы…").foregroundStyle(.secondary) }
                }
                ForEach(allStatuses) { s in
                    Toggle(isOn: Binding(
                        get: { settings.trackerStatusKeys.contains(s.key) },
                        set: { on in
                            if on { settings.trackerStatusKeys.append(s.key) }
                            else { settings.trackerStatusKeys.removeAll { $0 == s.key } }
                            Task { await tracker.refresh() }
                        }
                    )) {
                        HStack {
                            Text(s.name)
                            Text(s.key).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                }
                Button("По умолчанию: Беклог, Новый, Открыт, Будем делать, Подтверждён, В работе") {
                    settings.trackerStatusKeys = TaskFilter.defaultStatusKeys
                    Task { await tracker.refresh() }
                }
                .buttonStyle(.link)
            } header: {
                Text("Статусы во вкладке «Мои»")
            } footer: {
                Text("«В работе» всегда показывает только статус «В работе». «Ждут» показывает задачи, где ждут твоего ответа, в любом активном статусе.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Шаблон ветки", text: $settings.trackerBranchTemplate, prompt: Text("{key}-{slug}"))
                Text("Подстановки: {key} — DEV-2311, {slug} — название латиницей, {type} — fix для багов, feature для остального. Например: {type}/{key} или {key}-{slug}.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Копирование ветки")
            }

            Section {
                Toggle("Назначили на меня", isOn: $settings.trackerNotifyAssigned)
                Toggle("Ждут моего ответа (призыв)", isOn: $settings.trackerNotifyMention)
                Toggle("Новый комментарий", isOn: $settings.trackerNotifyComment)
                Toggle("Смена статуса", isOn: $settings.trackerNotifyStatus)
                Text("Уведомления строятся по изменениям в задачах, где ты исполнитель, автор, наблюдатель или тебя призвали. Свои действия не уведомляются.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Уведомления")
            }

            Section {
                Text(mcpCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Скопировать команду") { copyToPasteboard(mcpCommand, toast: "Команда скопирована") }
                Text("Используй в `~/.claude.json` → mcpServers → yandex-tracker как `sh -c \"…\"`. Тогда авторизация в Claude не будет слетать каждые 12 часов, как с IAM-токеном.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("MCP для Claude Code")
            }
        }
        .formStyle(.grouped)
        .task {
            // Только статусы, которые бывают у активных задач. Целевые (OKR) и служебные скрываем.
            let hidden: Set<String> = ["newGoal", "asPlanned", "withRisks", "blockedGoal", "achieved", "billPayed", "serviceProvided"]
            let list = (try? await TrackerAPI.statuses()) ?? []
            allStatuses = list
                .filter { ["new", "paused", "inProgress"].contains($0.type ?? "") && !hidden.contains($0.key) }
                .sorted { TaskFilter.rank($0.key) != TaskFilter.rank($1.key)
                    ? TaskFilter.rank($0.key) < TaskFilter.rank($1.key) : ($0.order ?? 0) < ($1.order ?? 0) }
        }
    }

    private func saveToken() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("y0_") || token.count > 30, !token.contains(" ") else {
            status = ("Это не похоже на токен: он начинается с y0_ и не содержит пробелов.", false)
            return
        }
        checking = true
        Task {
            do {
                let me = try await TrackerAPI.myself(token: token)
                if await TrackerAuth.saveToken(token) {
                    tokenInput = ""
                    status = ("Сохранено. Ты вошёл как \(me.display) (\(me.login))", true)
                    await tracker.refresh()
                } else {
                    status = ("Не удалось записать токен в Keychain", false)
                }
            } catch {
                status = (error.localizedDescription, false)
            }
            checking = false
        }
    }
}
