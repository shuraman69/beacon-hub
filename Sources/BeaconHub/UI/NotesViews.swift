import AppKit
import SwiftUI

/// Вкладка «Заметки»: строка быстрого ввода сверху, ниже карточки. Пункты чеклиста отмечаются прямо в списке.
struct NotesView: View {
    @ObservedObject var store: NotesStore
    let open: (UUID, Bool) -> Void

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Новая заметка, [] для чеклиста ↩", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(addQuick)
                Button { open(store.add(input), false); input = "" } label: { Image(systemName: "square.and.pencil") }
                    .help("Новая заметка")
                Button { open(store.add(input), true); input = "" } label: {
                    Image(systemName: "checklist")
                }
                .help("Новый чеклист")
            }
            .buttonStyle(.borderless)

            if store.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Заметок пока нет").foregroundStyle(.secondary)
                    Text("Введи текст и нажми ↩. Начни с [] и получится чеклист, пункты разделяй «;»: «[] молоко; хлеб».")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
            ForEach(store.sorted) { note in
                NoteCard(store: store, note: note, open: { open(note.id, false) })
            }
        }
        .onAppear { if store.notes.isEmpty { inputFocused = true } }
    }

    private func addQuick() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.add(text)
        input = ""
        inputFocused = true
    }
}

/// Карточка в списке. Клик открывает заметку, клик по чекбоксу отмечает пункт.
struct NoteCard: View {
    @ObservedObject var store: NotesStore
    let note: Note
    var maxItems = 5
    let open: () -> Void
    @State private var hovering = false

    private var visibleItems: [CheckItem] {
        // Сначала невыполненные: отмеченные пункты уходят вниз и скрываются, если не помещаются.
        Array((note.items.filter { !$0.done } + note.items.filter(\.done)).prefix(maxItems))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                Text(note.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering {
                    Button { store.update(note.id) { $0.pinned.toggle() } } label: {
                        Image(systemName: note.pinned ? "pin.slash" : "pin")
                    }
                    .help(note.pinned ? "Открепить" : "Закрепить в сводке")
                    Button { store.delete(note.id) } label: { Image(systemName: "trash") }
                        .help("Удалить")
                } else {
                    if let key = note.issueKey { Badge(text: key, color: .blue) }
                    if !note.items.isEmpty {
                        Badge(text: "\(note.doneCount)/\(note.items.count)",
                              color: note.doneCount == note.items.count ? .green : .secondary)
                    }
                }
            }
            .buttonStyle(.borderless)
            if !note.body.isEmpty && !note.title.isEmpty {
                Text(Linkify.attributed(note.body))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach(visibleItems) { item in
                CheckRow(item: item) { store.toggle(note.id, item: item.id) }
            }
            if note.items.count > maxItems {
                Text("ещё \(note.items.count - maxItems)").font(.caption).foregroundStyle(.tertiary).padding(.leading, 22)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0.045)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(note.pinned ? "Открепить" : "Закрепить в сводке") { store.update(note.id) { $0.pinned.toggle() } }
            Button("Скопировать текст") { copyToPasteboard(note.markdown, toast: "Заметка скопирована") }
            if note.doneCount > 0 {
                Button("Убрать выполненные") { store.update(note.id) { $0.items.removeAll(where: \.done) } }
            }
            Divider()
            Button("Удалить", role: .destructive) { store.delete(note.id) }
        }
    }
}

struct CheckRow: View {
    let item: CheckItem
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
                Text(item.text)
                    .font(.callout)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Редактирование заметки: название, текст, пункты, привязка к задаче.
struct NoteDetailView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var tracker: TrackerStore
    let id: UUID
    let focusItems: Bool
    let back: () -> Void

    @State private var newItem = ""
    @FocusState private var focus: Field?
    private enum Field: Hashable { case title, body, newItem, item(UUID) }

    private var note: Note? { store.note(id) }

    private func binding<T>(_ path: WritableKeyPath<Note, T>, default value: T) -> Binding<T> {
        Binding(get: { store.note(id)?[keyPath: path] ?? value },
                set: { v in store.update(id) { $0[keyPath: path] = v } })
    }

    var body: some View {
        if let note {
            VStack(alignment: .leading, spacing: 10) {
                toolbar(note)
                TextField("Название", text: binding(\.title, default: ""))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .focused($focus, equals: .title)
                bodyEditor
                checklist(note)
                Text("Создана \(Fmt.relative(note.createdAt)) · изменена \(Fmt.relative(note.updatedAt))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .onAppear {
                if focusItems { focus = .newItem } else if note.title.isEmpty && note.body.isEmpty { focus = .title }
            }
        } else {
            Button("‹ Заметки", action: back).buttonStyle(.link)
        }
    }

    // MARK: Шапка

    private func toolbar(_ note: Note) -> some View {
        HStack(spacing: 8) {
            Button { store.dropIfEmpty(id); back() } label: {
                Label("Заметки", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            Spacer()
            issueMenu(note)
            Button { store.update(id) { $0.pinned.toggle() } } label: {
                Image(systemName: note.pinned ? "pin.fill" : "pin").foregroundStyle(note.pinned ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(note.pinned ? "Открепить" : "Закрепить в сводке")
            Menu {
                Button("Скопировать текст") { copyToPasteboard(note.markdown, toast: "Заметка скопирована") }
                if note.doneCount > 0 {
                    Button("Убрать выполненные") { store.update(id) { $0.items.removeAll(where: \.done) } }
                    Button("Снять все отметки") { store.update(id) { n in n.items.indices.forEach { n.items[$0].done = false } } }
                }
                Divider()
                Button("Удалить заметку", role: .destructive) { store.delete(id); back() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Привязка к задаче трекера: из «В работе» и «Мои».
    private func issueMenu(_ note: Note) -> some View {
        let issues = (tracker.issues(.inProgress) + tracker.issues(.mine))
            .reduce(into: [TIssue]()) { acc, i in if !acc.contains(where: { $0.key == i.key }) { acc.append(i) } }
        return Menu {
            if let key = note.issueKey {
                Button("Открыть \(key) в трекере") { openURL("https://tracker.yandex.ru/\(key)") }
                Button("Отвязать") { store.update(id) { $0.issueKey = nil } }
                Divider()
            }
            if let timer = tracker.timer {
                Button("⏱ \(timer.key) · \(timer.summary)") { store.update(id) { $0.issueKey = timer.key } }
            }
            ForEach(issues.prefix(20)) { issue in
                Button("\(issue.key) · \(issue.summary)") { store.update(id) { $0.issueKey = issue.key } }
            }
            if issues.isEmpty && tracker.timer == nil { Text("Нет задач из трекера") }
        } label: {
            if let key = note.issueKey {
                Text(key).font(.caption.weight(.medium))
            } else {
                Image(systemName: "link")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(note.issueKey == nil ? "Привязать к задаче" : "Задача трекера")
    }

    // MARK: Текст

    private var bodyEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: binding(\.body, default: ""))
                .font(.callout)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .frame(minHeight: 54, maxHeight: 160)
            if (note?.body ?? "").isEmpty {
                Text("Текст заметки…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045)))
    }

    // MARK: Пункты

    private func checklist(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !note.items.isEmpty {
                HStack {
                    Text("Чеклист").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(note.doneCount) из \(note.items.count)").font(.caption).foregroundStyle(.secondary)
                }
                UsageBar(fraction: Double(note.doneCount) / Double(note.items.count), color: .green)
                    .padding(.bottom, 2)
            }
            ForEach(note.items) { item in
                EditableCheckRow(store: store, noteID: id, item: item)
            }
            HStack(spacing: 6) {
                Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 16)
                TextField("Пункт чеклиста ↩", text: $newItem)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .newItem)
                    .onSubmit {
                        store.addItems(id, newItem)
                        newItem = ""
                        focus = .newItem
                    }
            }
            .padding(.vertical, 3)
        }
    }
}

/// Пункт в режиме редактирования: чекбокс, редактируемый текст, удаление и перемещение при наведении.
struct EditableCheckRow: View {
    @ObservedObject var store: NotesStore
    let noteID: UUID
    let item: CheckItem
    @State private var hovering = false

    private var text: Binding<String> {
        Binding(get: { item.text },
                set: { v in store.update(noteID) { n in
                    if let j = n.items.firstIndex(where: { $0.id == item.id }) { n.items[j].text = v }
                } })
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { store.toggle(noteID, item: item.id) } label: {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.callout)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
            if hovering {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.help("Выше")
                Button { move(1) } label: { Image(systemName: "chevron.down") }.help("Ниже")
                Button {
                    store.update(noteID) { $0.items.removeAll { $0.id == item.id } }
                } label: { Image(systemName: "xmark") }.help("Удалить пункт")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
    }

    private func move(_ delta: Int) {
        store.update(noteID) { n in
            guard let j = n.items.firstIndex(where: { $0.id == item.id }) else { return }
            let k = j + delta
            guard n.items.indices.contains(k) else { return }
            n.items.swapAt(j, k)
        }
    }
}

/// Карточка закреплённых заметок для «Сводки».
struct PinnedNotesCard: View {
    @ObservedObject var store: NotesStore
    let openAll: () -> Void
    let open: (UUID) -> Void

    var body: some View {
        SectionCard(title: "Заметки", systemImage: "note.text") {
            Button("Все →", action: openAll).buttonStyle(.link).font(.caption)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.pinned.prefix(3)) { note in
                    NoteCard(store: store, note: note, maxItems: 4) { open(note.id) }
                }
            }
        }
    }
}
