import Foundation

/// A link pulled out of whatever was shared or pasted: a bare URL, or a chat message with a URL in it.
public struct SharedLink: Equatable, Sendable {
    public var url: URL
    public var kind: MediaKind
    /// The text around the URL ("you have to watch this 👇"), kept as a note.
    public var note: String

    /// Finds the first http(s) URL in `text`. Returns nil when there is none.
    public static func parse(_ text: String) -> SharedLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            var note = trimmed
            if let r = Range(match.range, in: trimmed) { note.removeSubrange(r) }
            note = note.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            return SharedLink(url: url, kind: SourceClassifier.kind(for: url), note: note)
        }
        return nil
    }
}
