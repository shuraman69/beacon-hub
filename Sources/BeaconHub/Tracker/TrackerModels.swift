import Foundation

struct TUser: Decodable, Hashable {
    let id: String
    let display: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = (try? c.decode(String.self, forKey: .display)) ?? ""
        // id приходит то строкой, то числом
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else if let n = try? c.decode(Int64.self, forKey: .id) { id = String(n) }
        else { id = "" }
    }

    private enum CodingKeys: String, CodingKey { case id, display }
}

/// Ссылка на справочник: статус, тип, приоритет, тип статуса.
struct TRef: Decodable, Hashable {
    let key: String?
    let display: String
}

struct TQueue: Decodable, Hashable {
    let key: String
}

struct TIssue: Decodable, Identifiable, Hashable {
    let key: String
    let summary: String
    let status: TRef
    let statusType: TRef?
    let type: TRef?
    let priority: TRef?
    let assignee: TUser?
    let updatedAt: Date?
    let spent: String?
    let pendingReplyFrom: [TUser]?
    let queue: TQueue?

    var id: String { key }
    var webURL: String { "https://tracker.yandex.ru/\(key)" }

    /// Имя ветки по шаблону из настроек: {key}, {slug}, {type} (fix для багов, feature для остального).
    var branchName: String {
        let template = UserDefaults.standard.string(forKey: "trackerBranchTemplate") ?? "{key}-{slug}"
        let typeName = type?.key == "bug" ? "fix" : "feature"
        let result = template
            .replacingOccurrences(of: "{key}", with: key)
            .replacingOccurrences(of: "{slug}", with: slug)
            .replacingOccurrences(of: "{type}", with: typeName)
        return result.replacingOccurrences(of: "--", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
    }

    var slug: String {
        let latin = summary.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? summary
        let slug = latin.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let short = slug.split(separator: "-").reduce(into: [String]()) { acc, word in
            if (acc.joined(separator: "-").count + word.count) < 45 { acc.append(String(word)) }
        }.joined(separator: "-")
        return short
    }
}

struct TTransition: Decodable, Identifiable, Hashable {
    let id: String
    let display: String
    let to: TRef
}

struct TComment: Decodable, Identifiable, Hashable {
    let id: Int
    let text: String?
    let createdBy: TUser?
    let createdAt: Date?

    /// Текст без YFM-разметки, ссылки кликабельны: и markdown-ссылки, и голые URL.
    var richText: AttributedString { Linkify.attributed(markdownText) }

    /// Текст без YFM-разметки (`{% block %}` и т. п.), markdown-ссылки сохраняются.
    var markdownText: String {
        (text ?? "")
            .replacingOccurrences(of: #"\{%[^%]*%\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #":file\[[^\]]*\]\([^)]*\)(\{[^}]*\})?"#, with: "📎 файл", options: .regularExpression)
            .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "🖼 картинка", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Текст без YFM-разметки (`{% block %}` и т. п.).
    var plainText: String {
        (text ?? "")
            .replacingOccurrences(of: #"\{%[^%]*%\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #":file\[[^\]]*\]\([^)]*\)(\{[^}]*\})?"#, with: "📎 файл", options: .regularExpression)
            .replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TMyself: Decodable {
    let uid: Int64
    let login: String
    let display: String
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case inProgress, waiting, mine, events

    var id: String { rawValue }
    var title: String {
        switch self {
        case .inProgress: return "В работе"
        case .waiting: return "Ждут"
        case .mine: return "Мои"
        case .events: return "События"
        }
    }

    /// Статусы «до В работе включительно» (ключи трекера). Настраиваются в Настройки → Трекер.
    static let defaultStatusKeys = ["inProgress", "selectedForDev", "confirmed", "open", "new", "backlog"]

    static var statusKeys: [String] {
        let saved = UserDefaults.standard.stringArray(forKey: "trackerStatusKeys") ?? defaultStatusKeys
        return saved.isEmpty ? defaultStatusKeys : saved
    }

    var query: String? {
        let statuses = "Status: " + Self.statusKeys.joined(separator: ", ")
        switch self {
        case .inProgress: return #"Assignee: me() Status: inProgress "Sort By": Updated DESC"#
        case .waiting: return #""Pending Reply From": me() "Status Type": inProgress, paused, new "Sort By": Updated DESC"#
        case .mine: return #"Assignee: me() \#(statuses) "Sort By": Updated DESC"#
        case .events: return nil
        }
    }

    /// Порядок в «Мои»: сначала то, что в работе, потом «надо делать», в конце беклог.
    static func rank(_ statusKey: String?) -> Int {
        ["inProgress", "selectedForDev", "confirmed", "open", "needInfo", "needEstimate", "new", "backlog"]
            .firstIndex(of: statusKey ?? "") ?? 50
    }

}

/// Событие для ленты «События» и системных уведомлений.
struct TrackerEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case assigned, mention, comment, status }

    let id: String
    let kind: Kind
    let issueKey: String
    let issueSummary: String
    let text: String
    let author: String
    let date: Date
    var read = false

    var icon: String {
        switch kind {
        case .assigned: return "person.crop.circle.badge.plus"
        case .mention: return "at"
        case .comment: return "text.bubble"
        case .status: return "arrow.triangle.swap"
        }
    }
}

/// Запущенный таймер на задаче. Хранится в UserDefaults и переживает перезапуск.
struct TrackerTimer: Codable, Equatable {
    let key: String
    let summary: String
    let startedAt: Date
}

/// ISO-8601 длительности трекера (`PT3H10M`, `P1DT2H`, `P1W`).
enum TDuration {
    static func components(_ iso: String) -> (w: Int, d: Int, h: Int, m: Int) {
        func value(_ unit: String, in part: Substring) -> Int {
            guard let r = part.range(of: #"(\d+)"# + unit, options: .regularExpression) else { return 0 }
            return Int(part[r].dropLast()) ?? 0
        }
        let parts = iso.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        let date = parts.first ?? ""
        let time = parts.count > 1 ? parts[1] : ""
        return (value("W", in: date), value("D", in: date), value("H", in: time), value("M", in: time))
    }

    static func display(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let c = components(iso)
        var out: [String] = []
        if c.w > 0 { out.append("\(c.w) нед") }
        if c.d > 0 { out.append("\(c.d) д") }
        if c.h > 0 { out.append("\(c.h) ч") }
        if c.m > 0 { out.append("\(c.m) мин") }
        return out.isEmpty ? nil : out.joined(separator: " ")
    }

    static func iso(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "PT\(h)H\(m)M" }
        if h > 0 { return "PT\(h)H" }
        return "PT\(max(m, 1))M"
    }

    /// Разбирает ввод пользователя: «1ч 30м», «1h30m», «90», «1.5ч», «45м».
    static func parseMinutes(_ input: String) -> Int? {
        let s = input.lowercased().replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
        if s.isEmpty { return nil }
        if let plain = Double(s) { return Int((plain).rounded()) } // просто число — минуты
        var total = 0.0
        var matched = false
        let patterns: [(String, Double)] = [(#"([\d.]+)(ч|h)"#, 60), (#"([\d.]+)(м|мин|m|min)"#, 1)]
        for (pattern, mult) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(match.range(at: 1), in: s), let v = Double(s[r]) {
                    total += v * mult
                    matched = true
                }
            }
        }
        return matched && total > 0 ? Int(total.rounded()) : nil
    }
}

/// Делает ссылки в тексте кликабельными.
enum Linkify {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ markdown: String) -> AttributedString {
        // 1. Inline-markdown: [текст](url), **жирный**, `код`. Переводы строк сохраняем.
        let base = (try? AttributedString(markdown: markdown,
                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        // 2. Голые URL, которые markdown не распознал.
        let ns = NSMutableAttributedString(base)
        let full = NSRange(location: 0, length: ns.length)
        detector?.enumerateMatches(in: ns.string, range: full) { match, _, _ in
            guard let match, let url = match.url else { return }
            if ns.attribute(.link, at: match.range.location, effectiveRange: nil) == nil {
                ns.addAttribute(.link, value: url, range: match.range)
            }
        }
        return (try? AttributedString(ns, including: \.foundation)) ?? base
    }
}

/// Комментарии к переходам статуса. Некоторые переходы трекер не выполняет без комментария:
/// такие запоминаем, чтобы в следующий раз сразу показать поле, а текст, который ввёл пользователь,
/// подставляем по умолчанию для того же целевого статуса.
enum TransitionComments {
    private static let requiredKey = "trackerTransitionsNeedComment"
    private static let textsKey = "trackerTransitionComments"

    private static func id(_ t: TTransition, _ issue: TIssue) -> String { "\(issue.queue?.key ?? "")/\(t.id)" }

    static func isRequired(_ t: TTransition, _ issue: TIssue) -> Bool {
        (UserDefaults.standard.stringArray(forKey: requiredKey) ?? []).contains(id(t, issue))
    }

    static func markRequired(_ t: TTransition, _ issue: TIssue) {
        var list = UserDefaults.standard.stringArray(forKey: requiredKey) ?? []
        if !list.contains(id(t, issue)) { list.append(id(t, issue)) }
        UserDefaults.standard.set(list, forKey: requiredKey)
    }

    static func defaultText(for t: TTransition) -> String {
        let saved = UserDefaults.standard.dictionary(forKey: textsKey) as? [String: String] ?? [:]
        if let text = saved[t.to.key ?? t.to.display] { return text }
        let key = (t.to.key ?? "").lowercased()
        let name = t.to.display.lowercased()
        if key.contains("test") || name.contains("тест") { return "Готово к тестированию" }
        if key.contains("review") || name.contains("ревью") { return "Готово к ревью" }
        if key == "inprogress" || name.contains("в работе") { return "Взял в работу" }
        if key.contains("needinfo") || name.contains("информац") { return "Нужна дополнительная информация" }
        if ["closed", "resolved", "done"].contains(where: key.contains) || name.contains("закрыт") || name.contains("решен") {
            return "Готово"
        }
        return "Перевожу в «\(t.to.display)»"
    }

    static func remember(_ text: String, for t: TTransition) {
        var saved = UserDefaults.standard.dictionary(forKey: textsKey) as? [String: String] ?? [:]
        saved[t.to.key ?? t.to.display] = text
        UserDefaults.standard.set(saved, forKey: textsKey)
    }
}
