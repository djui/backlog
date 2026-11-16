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

    /// A typed tag name as it would be stored ("#Home workout" → "Home-workout"), or nil if it
    /// isn't a valid tag.
    public static func normalize(_ name: String) -> String? {
        var t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        guard !t.isEmpty, t.range(of: #"^[\p{L}\p{N}_-]+$"#, options: .regularExpression) != nil else { return nil }
        return t
    }

    /// The note with tag `old` (any capitalization) renamed to `new`, where it stands. If the note
    /// already has `new`, the two merge into one. The rest of the note is left as written.
    public static func rename(_ old: String, to new: String, in note: String) -> String {
        guard let new = normalize(new), let old = normalize(old) else { return note }
        let oldKey = old.lowercased(), newKey = new.lowercased()
        let ns = note as NSString
        let matches = pattern.matches(in: note, range: NSRange(location: 0, length: ns.length))
        guard matches.contains(where: { ns.substring(with: $0.range(at: 1)).lowercased() == oldKey }) else { return note }

        // Decide what each tag becomes; a second copy of the same tag is dropped.
        var seen = Set<String>()
        var edits: [(NSRange, String)] = []
        for m in matches {
            let tag = ns.substring(with: m.range(at: 1))
            let isOld = tag.lowercased() == oldKey
            let key = isOld ? newKey : tag.lowercased()
            if !seen.insert(key).inserted {
                // Take the space before it too, so no double space is left behind.
                var r = m.range
                if r.location > 0, ns.substring(with: NSRange(location: r.location - 1, length: 1)) == " " {
                    r = NSRange(location: r.location - 1, length: r.length + 1)
                }
                edits.append((r, ""))
            } else if isOld {
                edits.append((m.range, "#" + new))
            }
        }
        let out = NSMutableString(string: note)
        for (range, text) in edits.reversed() { out.replaceCharacters(in: range, with: text) }
        return (out as String).trimmingCharacters(in: .whitespaces)
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
