import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let tools: ToolsController

    var body: some View {
        TabView {
            GitLabSettingsView(settings: settings)
                .tabItem { Label("GitLab", systemImage: "arrow.triangle.branch") }
            TrackerSettingsView(settings: settings, tracker: state.tracker)
                .tabItem { Label("Трекер", systemImage: "checklist") }
            ClaudeSettingsView(state: state, settings: settings)
                .tabItem { Label("Claude", systemImage: "sparkle") }
            ToolsSettingsView(settings: settings, tools: tools, store: tools.clipboardStore)
                .tabItem { Label("Инструменты", systemImage: "wand.and.stars") }
            GeneralSettingsView(settings: settings)
                .tabItem { Label("Общие", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 600)
    }
}

// MARK: - GitLab

struct GitLabSettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var accounts: [GitLabAccount] = []
    @State private var selectedHost = ""
    @State private var query = ""
    @State private var results: [GLProject] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var showAddHost = false
    @State private var searchTask: Task<Void, Never>?

    private var multiHost: Bool { Set(settings.projects.map(\.host)).count > 1 }

    var body: some View {
        Form {
            Section {
                if accounts.isEmpty {
                    Text("Аккаунты не найдены. Установи glab (`brew install glab`) и выполни `glab auth login`. Beacon Hub подхватит его автоматически. Можно и вручную добавить хост с токеном.")
                        .foregroundStyle(.secondary)
                }
                ForEach(accounts) { account in
                    HStack {
                        Image(systemName: account.token == nil ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(account.token == nil ? .orange : .green)
                        VStack(alignment: .leading) {
                            Text(account.host)
                            Text(subtitle(account)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if account.source == .manual {
                            Button("Удалить", role: .destructive) {
                                GitLabAccounts.removeManual(host: account.host)
                                reloadAccounts()
                            }
                        }
                    }
                }
                HStack {
                    Button("Добавить хост с токеном…") { showAddHost = true }
                    Button("Перечитать glab") { reloadAccounts() }
                }
            } header: {
                Text("Аккаунты")
            }

            Section {
                if settings.projects.isEmpty {
                    Text("Пока пусто. Найди проект ниже и нажми «+».").foregroundStyle(.secondary)
                }
                ForEach(settings.projects) { project in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.path)
                            if multiHost { Text(project.host).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button {
                            settings.toggleProject(project)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onMove { settings.projects.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Отслеживаемые проекты")
            }

            Section {
                Picker("Хост", selection: $selectedHost) {
                    ForEach(accounts) { Text($0.host).tag($0.host) }
                }
                HStack {
                    TextField("Поиск по названию или группе", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)
                    if searching { ProgressView().controlSize(.small) }
                }
                if let searchError { ErrorLine(text: searchError) }
                ForEach(results) { project in
                    let ref = ProjectRef(host: selectedHost, projectId: project.id,
                                         path: project.pathWithNamespace, webURL: project.webUrl)
                    let added = settings.projects.contains { $0.id == ref.id }
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.name)
                            Text(project.pathWithNamespace).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            settings.toggleProject(ref)
                        } label: {
                            Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                                .foregroundStyle(added ? .green : .accentColor)
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help(added ? "Убрать" : "Отслеживать")
                    }
                }
            } header: {
                Text("Добавить проект")
            }

            Section {
                Stepper("Пайплайнов на проект: \(settings.pipelinesPerProject)",
                        value: $settings.pipelinesPerProject, in: 1...10)
                Toggle("Только мои пайплайны", isOn: $settings.onlyMyPipelines)
                Toggle("Показывать секцию GitLab", isOn: $settings.showGitLab)
            } header: {
                Text("Отображение")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reloadAccounts()
            search()
        }
        .onChange(of: selectedHost) { search() }
        .onChange(of: query) {
            // Небольшой debounce, чтобы не дёргать API на каждую букву.
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !Task.isCancelled { search() }
            }
        }
        .sheet(isPresented: $showAddHost) {
            AddHostSheet { host in
                reloadAccounts()
                selectedHost = host
            }
        }
    }

    private func subtitle(_ a: GitLabAccount) -> String {
        var parts: [String] = [a.source == .glab ? "из glab" : "токен в Keychain"]
        if let user = a.user { parts.insert("@\(user)", at: 0) }
        if a.token == nil { parts.append("нет токена") }
        return parts.joined(separator: " · ")
    }

    private func reloadAccounts() {
        accounts = GitLabAccounts.all()
        if !accounts.contains(where: { $0.host == selectedHost }) {
            selectedHost = accounts.first?.host ?? ""
        }
    }

    private func search() {
        guard !selectedHost.isEmpty else { return }
        let host = selectedHost, q = query
        searching = true
        Task {
            do {
                let found = try await GitLabProvider.searchProjects(host: host, query: q)
                if host == selectedHost && q == query {
                    results = found
                    searchError = nil
                }
            } catch {
                searchError = error.localizedDescription
                results = []
            }
            searching = false
        }
    }
}

struct AddHostSheet: View {
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var url = "https://gitlab.com"
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?

    private var host: String? { GitLabAccounts.normalizeHost(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Добавить GitLab по токену").font(.title3.weight(.semibold))
            Text("Нужен Personal Access Token со scope **read_api**. Токен хранится в Keychain.")
                .foregroundStyle(.secondary)
            TextField("URL инстанса", text: $url).textFieldStyle(.roundedBorder)
            SecureField("Токен (glpat-…)", text: $token).textFieldStyle(.roundedBorder)
            Button("Создать токен в GitLab ↗") {
                guard let host else { return }
                openURL("https://\(host)/-/user_settings/personal_access_tokens?name=Beacon%20Hub&scopes=read_api")
            }
            .buttonStyle(.link)
            .disabled(host == nil)
            if let error { ErrorLine(text: error) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Проверить и сохранить", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host == nil || token.isEmpty || checking)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        guard let host else { return }
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        Task {
            do {
                _ = try await GitLabAPI.validate(host: host, token: t)
                GitLabAccounts.addManual(host: host, token: t)
                onSaved(host)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            checking = false
        }
    }
}

// MARK: - Claude

struct ClaudeSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                HStack {
                    if let usage = state.claudeUsage, state.claudeError == nil {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Подключено через Claude Code" + (usage.plan.map { " · план \($0)" } ?? ""))
                    } else if let error = state.claudeError {
                        ErrorLine(text: error)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Проверяю…")
                    }
                    Spacer()
                    Button("Проверить") { Task { await state.refresh(force: true) } }
                }
                Text("Логин не нужен: Beacon Hub читает токен, который Claude Code хранит в Keychain, и запрашивает те же лимиты, что команда /usage. Если сессия истечёт, просто запусти claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Подключение")
            }

            Section {
                Toggle("Показывать лимиты Claude", isOn: $settings.showClaude)
                Toggle("Запрашивать лимиты только через VPN", isOn: $settings.claudeRequireVPN)
                    .onChange(of: settings.claudeRequireVPN) { _, _ in Task { await state.refresh(force: true) } }
                Text("Когда включено, запрос к api.anthropic.com уходит только через VPN-туннель (Happ, WireGuard, Outline и т. п.) или системный прокси VPN-клиента. Wi-Fi, Ethernet и сотовая сеть для него запрещены, поэтому без VPN запрос физически не отправится и реальный IP не попадёт к Anthropic. Если хост исключён из туннеля, запрос тоже не уйдёт.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Процент в статус-баре", selection: $settings.menuBarPercent) {
                    ForEach(MenuBarPercent.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Отображение")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Общие

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Интервал обновления", selection: $settings.refreshInterval) {
                    Text("30 секунд").tag(30.0)
                    Text("1 минута").tag(60.0)
                    Text("2 минуты").tag(120.0)
                    Text("5 минут").tag(300.0)
                }
                Text("Пока пайплайн идёт, GitLab опрашивается каждые 15 с. Claude не чаще раза в 90 с.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError { ErrorLine(text: loginError) }
            } header: {
                Text("Работа")
            }

            Section {
                Toggle("Показывать вкладку «Заметки»", isOn: $settings.showNotes)
                Text("Заметки и чеклисты хранятся только на этом Маке: ~/Library/Application Support/BeaconHub/Notes. Закреплённые видны в «Сводке».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Заметки")
            }

            Section {
                Toggle("Пайплайн упал", isOn: $settings.notifyFailed)
                Toggle("Пайплайн прошёл успешно", isOn: $settings.notifySuccess)
            } header: {
                Text("Уведомления")
            }

            Section {
                LabeledContent("Версия", value: "\(AppInfo.version) (\(AppInfo.build))")
            }
        }
        .formStyle(.grouped)
    }
}
