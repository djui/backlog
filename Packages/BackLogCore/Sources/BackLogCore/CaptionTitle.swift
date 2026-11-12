import Foundation

/// Titles for posts that don't have one. Instagram reels and posts only have a caption, and
/// yt-dlp calls them "Video by <user>"; a title made from the caption's opening is far easier to
/// recognize and find again.
public enum CaptionTitle {
    /// Whether `title` is a placeholder rather than a real title.
    public static func isGeneric(_ title: String, author: String = "", url: String = "") -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if t.isEmpty || t == url || lower == "instagram" || lower == "tiktok" { return true }
        if !author.isEmpty, lower == author.lowercased() || lower == "@" + author.lowercased() { return true }
        for prefix in ["video by ", "post by ", "reel by ", "photo by ", "instagram post by ", "instagram video by "] where lower.hasPrefix(prefix) {
            return true
        }
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// The caption inside an Instagram page title: `Name on Instagram: "caption…"`.
    public static func instagramCaption(fromPageTitle title: String) -> String? {
        guard let r = title.range(of: " on Instagram: ") else { return nil }
        var caption = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        for q in ["\"", "“", "”"] {
            if caption.hasPrefix(q) { caption.removeFirst() }
            if caption.hasSuffix(q) { caption.removeLast() }
        }
        return caption.isEmpty ? nil : caption
    }

    /// The caption's first meaningful line, without hashtags, mentions, links and trailing emoji,
    /// cut at the first sentence when that's long enough, and at most `limit` characters.
    public static func make(from caption: String, limit: Int = 90) -> String? {
        let lines = caption.components(separatedBy: .newlines)
        for raw in lines {
            var line = raw
            for pattern in [#"https?://\S+"#, #"(?<!\w)#[\p{L}\p{N}_]+"#, #"(?<!\w)@[\w.]+"#] {
                line = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "!?\"'“”()")))
            // Lines of only emoji or symbols aren't a title.
            guard line.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }), line.count >= 3 else { continue }
            if let end = line.firstIndex(where: { ".!?".contains($0) }), line.distance(from: line.startIndex, to: end) >= 20 {
                line = String(line[...end])
            }
            if line.count > limit {
                let cut = line.prefix(limit)
                line = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
            }
            return line
        }
        return nil
    }
}
