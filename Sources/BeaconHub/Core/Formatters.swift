import Foundation

enum DateParser {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()
    /// Формат Яндекс Трекера: `2026-11-11T08:10:34.830+0000`.
    private static let tracker: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    /// Понимает и `...Z`, и `.123Z`, и микросекунды `.748368+00:00`, и `+0000` без двоеточия.
    static func parse(_ s: String) -> Date? {
        if let d = withFraction.date(from: s) ?? plain.date(from: s) ?? tracker.date(from: s) { return d }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let trimmed = s.replacingCharacters(in: r, with: s[r].prefix(4))
            return withFraction.date(from: trimmed)
        }
        return nil
    }
}

enum Fmt {
    private static let ru = Locale(identifier: "ru_RU")

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = ru
        f.unitsStyle = .short
        return f
    }()

    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = "EE, d MMM, HH:mm"
        return f
    }()

    /// «5 мин назад», «только что».
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 10 { return "только что" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    /// «2 ч 14 мин», «45 мин», «3 д 4 ч».
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d) д \(h) ч" : "\(d) д" }
        if h > 0 { return m > 0 ? "\(h) ч \(m) мин" : "\(h) ч" }
        if m > 0 { return "\(m) мин" }
        return "\(s) с"
    }

    /// Часы таймера: «0:42», «1:05:30».
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Подпись про сброс лимита: ближний — «через 2 ч 14 мин», дальний — «чт, 13 нояб., 20:00».
    static func reset(_ date: Date, now: Date = Date()) -> String {
        let left = date.timeIntervalSince(now)
        if left <= 0 { return "сброс сейчас" }
        if left < 24 * 3600 { return "сброс через \(duration(left))" }
        return "сброс \(weekdayTime.string(from: date)) · через \(duration(left))"
    }
}
