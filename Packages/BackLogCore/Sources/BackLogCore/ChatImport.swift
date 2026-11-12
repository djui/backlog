import Foundation

/// Links found in pasted chat history (a WhatsApp or Messages export) or any text with several
/// links: each with the time it was shared and who shared it, when the text says so.
public enum ChatImport {
    public struct Entry: Equatable, Sendable {
        public var link: SharedLink
        public var date: Date?
        public var sender: String?
    }

    /// iOS WhatsApp: `[2026-08-16, 06:37:56] Name: text` (also `[16.08.26, 06:37:56]`).
    /// Android WhatsApp: `16/08/2026, 06:37 - Name: text`.
    static let linePatterns = [
        #"^‎?\[(\d{1,4}[-./]\d{1,2}[-./]\d{1,4}),? (\d{1,2}:\d{2}(?::\d{2})?)\] ([^:]{1,60}): (.*)$"#,
        #"^‎?(\d{1,4}[-./]\d{1,2}[-./]\d{1,4}),? (\d{1,2}:\d{2}(?::\d{2})?) - ([^:]{1,60}): (.*)$"#,
    ]

    /// Every link in `text`, in order, once each. Lines in a chat export carry their date and sender;
    /// a message continued over several lines keeps the date of its first line.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> [Entry] {
        let regexes = linePatterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var entries: [Entry] = []
        var seen = Set<String>()
        var currentDate: Date?
        var currentSender: String?
        for raw in text.components(separatedBy: .newlines) {
            var body = raw
            let ns = raw as NSString
            for regex in regexes {
                guard let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
                currentDate = date(ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)), timeZone: timeZone)
                currentSender = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
                body = ns.substring(with: m.range(at: 4))
                break
            }
            for link in links(in: body) {
                let key = SourceClassifier.canonical(link.url).absoluteString
                guard seen.insert(key).inserted else { continue }
                entries.append(Entry(link: link, date: currentDate, sender: currentSender))
            }
        }
        return entries
    }

    /// All http(s) links in one message, each with the message's other text as its note.
    static func links(in text: String) -> [SharedLink] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { ["http", "https"].contains($0.url?.scheme?.lowercased() ?? "") }
        var note = text
        for m in matches.reversed() { note = (note as NSString).replacingCharacters(in: m.range, with: "") }
        note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return matches.compactMap { m in
            m.url.map { SharedLink(url: $0, kind: SourceClassifier.kind(for: $0), note: note) }
        }
    }

    /// Year-month-day or day-month-year (two- or four-digit years) and a time, in `timeZone`.
    static func date(_ day: String, _ time: String, timeZone: TimeZone) -> Date? {
        let parts = day.split(whereSeparator: { "-./".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var (y, m, d) = parts[0] > 31 ? (parts[0], parts[1], parts[2]) : (parts[2], parts[1], parts[0])
        if y < 100 { y += 2000 }
        if m > 12, d <= 12 { swap(&m, &d) }  // US order
        let t = time.split(separator: ":").compactMap { Int($0) }
        var c = DateComponents()
        (c.year, c.month, c.day) = (y, m, d)
        (c.hour, c.minute, c.second) = (t.first, t.count > 1 ? t[1] : 0, t.count > 2 ? t[2] : 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: c)
    }
}
