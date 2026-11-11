import Combine
import Foundation

struct CheckItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var done = false
}

/// Заметка. Если у неё есть пункты, это чеклист. Отдельного типа нет: в любую заметку можно добавить пункты.
struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var body = ""
    var items: [CheckItem] = []
    var pinned = false
    var issueKey: String?
    var createdAt = Date()
    var updatedAt = Date()

    init(title: String) { self.title = title }

    var doneCount: Int { items.filter(\.done).count }
    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && items.isEmpty
    }
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Без названия" : firstLine
    }

    /// Текст для копирования: markdown с чекбоксами.
    var markdown: String {
        var lines: [String] = []
        if !title.isEmpty { lines.append(title) }
        if !body.isEmpty { lines.append(body) }
        lines += items.map { "- [\($0.done ? "x" : " ")] \($0.text)" }
        return lines.joined(separator: "\n")
    }

    // Новые поля в будущем не должны ломать старый файл, поэтому всё читаем через decodeIfPresent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        items = try c.decodeIfPresent([CheckItem].self, forKey: .items) ?? []
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        issueKey = try c.decodeIfPresent(String.self, forKey: .issueKey)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// Заметки и чеклисты. Хранятся локально в `~/Library/Application Support/BeaconHub/Notes/notes.json`.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    init() {
        if let override = ProcessInfo.processInfo.environment["BEACONHUB_NOTES_FILE"] {
            fileURL = URL(fileURLWithPath: override)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = base.appendingPathComponent("BeaconHub/Notes/notes.json")
        }
        load()
    }

    /// Закреплённые сверху, дальше по дате изменения.
    var sorted: [Note] {
        notes.sorted { a, b in a.pinned != b.pinned ? a.pinned : a.updatedAt > b.updatedAt }
    }

    var pinned: [Note] { sorted.filter(\.pinned) }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    func notes(for issueKey: String) -> [Note] { sorted.filter { $0.issueKey == issueKey } }

    // MARK: Изменения

    /// Быстрое создание из строки. `[] купить` или `- [ ] купить` создаёт чеклист с первым пунктом
    /// `a; b; c` после префикса превращается в несколько пунктов.
    @discardableResult
    func add(_ raw: String, issueKey: String? = nil) -> UUID {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = Note(title: text)
        for prefix in ["- [ ]", "[ ]", "[]"] where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            note.title = ""
            note.items = rest.split(separator: ";").map { CheckItem(text: $0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.text.isEmpty }
            break
        }
        note.issueKey = issueKey
        notes.append(note)
        save()
        return note.id
    }

    func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var copy = notes[i]
        change(&copy)
        // Поля ввода присваивают значение и без правки: такие «изменения» не трогают дату и не пишутся.
        guard copy != notes[i] else { return }
        copy.updatedAt = Date()
        notes[i] = copy
        save()
    }

    func toggle(_ id: UUID, item: UUID) {
        update(id) { note in
            if let j = note.items.firstIndex(where: { $0.id == item }) { note.items[j].done.toggle() }
        }
    }

    func addItems(_ id: UUID, _ raw: String) {
        let parts = raw.split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: #"^(- )?\[[ x]?\]\s*"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        update(id) { $0.items += parts.map { CheckItem(text: $0) } }
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    /// Пустую заметку, из которой просто вышли, не храним.
    func dropIfEmpty(_ id: UUID) {
        if note(id)?.isEmpty == true { delete(id) }
    }

    // MARK: Файл

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        notes = (try? decoder.decode([Note].self, from: data)) ?? []
    }

    /// Пишем с задержкой 0,4 с: при наборе текста не дёргаем диск на каждую букву.
    private func save() {
        saveWork?.cancel()
        let snapshot = notes
        let url = fileURL
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// При выходе из приложения сохраняем сразу.
    func flush() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(notes) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
