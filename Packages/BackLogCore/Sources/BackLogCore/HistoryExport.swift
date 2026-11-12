import Foundation

/// One finished (or saved) item, as written to the History export.
public struct ExportEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var type: String
    public var status: String
    public var added: Date
    public var consumed: Date?
    public var author: String?
    public var site: String?
    public var published: Date?
    public var durationMinutes: Int?
    public var sharedBy: String?
    public var note: String?
    public var description: String?
    public var takeaway: String?
    public var keyPoints: [String]

    public init(id: UUID, url: String, title: String, type: String, status: String, added: Date, consumed: Date?,
                author: String? = nil, site: String? = nil, published: Date? = nil, durationMinutes: Int? = nil,
                sharedBy: String? = nil, note: String? = nil, description: String? = nil, takeaway: String? = nil,
                keyPoints: [String] = []) {
        self.id = id; self.url = url; self.title = title; self.type = type; self.status = status
        self.added = added; self.consumed = consumed; self.author = author; self.site = site
        self.published = published; self.durationMinutes = durationMinutes; self.sharedBy = sharedBy
        self.note = note; self.description = description; self.takeaway = takeaway; self.keyPoints = keyPoints
    }

    /// The day an entry belongs to: when it was finished, else when it was added.
    public var date: Date { consumed ?? added }
}

/// Writes History as Markdown, one file per day, easy for people and importers alike:
///
///     YYYY/YYYY-MM-DD.md   front matter (date, source, count), then one `## HH:mm · Status · Title`
///                           section per item with a `- key: value` list, the TL;DR as a quote and
///                           the key points as a list.
///     backlog.jsonl        every entry as one JSON object per line (the same fields), for importers
///                           that prefer structured data.
///
/// Keys are stable and lower-case; values are single-line; dates are ISO 8601 with offset.
public enum HistoryExport {
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func relativePath(forDay day: String) -> String {
        "\(day.prefix(4))/\(day).md"
    }

    public static func markdown(day: String, entries: [ExportEntry], timeZone: TimeZone = .current) -> String {
        let sorted = entries.sorted { $0.date < $1.date }
        var out = "---\ndate: \(day)\nsource: backlog\ncount: \(sorted.count)\n---\n"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        time.timeZone = timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]

        for e in sorted {
            out += "\n## \(time.string(from: e.date)) · \(e.status.capitalized) · \(oneLine(e.title))\n\n"
            var fields: [(String, String?)] = [
                ("id", e.id.uuidString.lowercased()),
                ("url", e.url),
                ("type", e.type),
                ("status", e.status),
                ("added", iso.string(from: e.added)),
                ("consumed", e.consumed.map(iso.string(from:))),
                ("author", e.author),
                ("site", e.site),
                ("published", e.published.map { dayKey($0) }),
                ("duration", e.durationMinutes.map { "\($0) min" }),
                ("from", e.sharedBy),
                ("note", e.note),
            ]
            fields = fields.filter { ($0.1 ?? "").isEmpty == false }
            for (key, value) in fields { out += "- \(key): \(oneLine(value!))\n" }
            if let t = e.takeaway, !t.isEmpty { out += "\n> \(oneLine(t))\n" }
            if !e.keyPoints.isEmpty {
                out += "\n" + e.keyPoints.map { "- \(oneLine($0))" }.joined(separator: "\n") + "\n"
            } else if let d = e.description, !d.isEmpty, e.takeaway == nil {
                out += "\n> \(oneLine(String(d.prefix(500))))\n"
            }
        }
        return out
    }

    public static func jsonLines(_ entries: [ExportEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return entries.sorted { $0.date < $1.date }
            .compactMap { try? String(decoding: encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
    }

    /// Writes every day's file and the JSONL into `folder`. Only files whose content changed are
    /// rewritten, so sync tools and importers see real changes only. Returns the number written.
    @discardableResult
    public static func write(_ entries: [ExportEntry], to folder: URL) throws -> Int {
        let fm = FileManager.default
        var written = 0
        func put(_ text: String, _ url: URL) throws {
            if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            written += 1
        }
        let byDay = Dictionary(grouping: entries) { dayKey($0.date) }
        for (day, dayEntries) in byDay {
            try put(markdown(day: day, entries: dayEntries), folder.appending(path: relativePath(forDay: day)))
        }
        try put(jsonLines(entries), folder.appending(path: "backlog.jsonl"))
        return written
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
