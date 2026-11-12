import Foundation

/// Tags live in an item's note as #hashtags ("Clever engineering #cars #design"), so they sync
/// and search like the rest of the note.
public enum Tags {
    static let pattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])#([\p{L}\p{N}_-]+)"#)

    /// The tags in a note, in order, each once (case-insensitively).
    public static func parse(_ note: String) -> [String] {
        let ns = note as NSString
        var seen = Set<String>()
        return pattern.matches(in: note, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let tag = ns.substring(with: m.range(at: 1))
            return seen.insert(tag.lowercased()).inserted ? tag : nil
        }
    }

    /// The note without its tags.
    public static func strip(_ note: String) -> String {
        let ns = note as NSString
        return pattern.stringByReplacingMatches(in: note, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// A note with tags appended (spaces in a tag become dashes).
    public static func compose(note: String, tags: [String]) -> String {
        let clean = tags.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-") }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = clean.filter { seen.insert($0.lowercased()).inserted }
        return ([note.trimmingCharacters(in: .whitespacesAndNewlines)] + unique.map { "#\($0)" })
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Values to suggest while typing: most recent first, filtered by what's typed so far.
public enum Suggestions {
    public static func rank(_ recent: [String], presets: [String] = [], typed: String, excluding: [String] = [], limit: Int = 8) -> [String] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let excluded = Set(excluding.map { $0.lowercased() })
        var seen = Set<String>()
        return (recent + presets).filter { value in
            let key = value.lowercased()
            guard !value.isEmpty, !excluded.contains(key), seen.insert(key).inserted else { return false }
            return q.isEmpty || key.hasPrefix(q) || key.contains(" " + q) || (key.contains(q) && q.count >= 2)
        }
        .prefix(limit).map { $0 }
    }

    /// Adds a used value to the front of a recents list.
    public static func remember(_ value: String, in list: [String], max: Int = 30) -> [String] {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return list }
        return Array(([v] + list.filter { $0.lowercased() != v.lowercased() }).prefix(max))
    }
}
