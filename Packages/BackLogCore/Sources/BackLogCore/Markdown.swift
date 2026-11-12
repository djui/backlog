import Foundation

/// Converts the cleaned article HTML that Readability returns into Markdown. It handles the
/// elements articles use (headings, paragraphs, lists, quotes, code, links, images, emphasis);
/// anything else becomes its text.
public enum MarkdownConverter {
    public static func markdown(fromHTML html: String) -> String {
        var s = html
        func re(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        // Drop things that never belong in text.
        re(#"<(script|style|noscript|svg|iframe|form|button)[^>]*>[\s\S]*?</\1>"#, "")
        re(#"<!--[\s\S]*?-->"#, "")
        // Code blocks first, so their content isn't touched by inline rules. (Simple approach: keep text.)
        re(#"<pre[^>]*>\s*(?:<code[^>]*>)?([\s\S]*?)(?:</code>)?\s*</pre>"#, "\n\n```\n$1\n```\n\n")
        for level in 1...6 {
            re("<h\(level)[^>]*>([\\s\\S]*?)</h\(level)>", "\n\n" + String(repeating: "#", count: level) + " $1\n\n")
        }
        re(#"<img[^>]*?src\s*=\s*"([^"]+)"[^>]*?alt\s*=\s*"([^"]*)"[^>]*>"#, "![$2]($1)")
        re(#"<img[^>]*?alt\s*=\s*"([^"]*)"[^>]*?src\s*=\s*"([^"]+)"[^>]*>"#, "![$1]($2)")
        re(#"<img[^>]*?src\s*=\s*"([^"]+)"[^>]*>"#, "![]($1)")
        re(#"<a[^>]*?href\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)</a>"#, "[$2]($1)")
        re(#"<(strong|b)(\s[^>]*)?>([\s\S]*?)</\1>"#, "**$3**")
        re(#"<(em|i)(\s[^>]*)?>([\s\S]*?)</\1>"#, "*$3*")
        re(#"<code[^>]*>([\s\S]*?)</code>"#, "`$1`")
        re(#"<blockquote[^>]*>([\s\S]*?)</blockquote>"#, "\n\n> $1\n\n")
        re(#"<li[^>]*>"#, "\n- ")
        re(#"</li>"#, "")
        re(#"</?(ul|ol)[^>]*>"#, "\n\n")
        re(#"<br\s*/?>"#, "  \n")
        re(#"<hr[^>]*>"#, "\n\n---\n\n")
        re(#"</?(p|div|section|article|figure|figcaption|header|footer|table|tr)[^>]*>"#, "\n\n")
        re(#"</?(td|th)[^>]*>"#, " ")
        re(#"<[^>]+>"#, "")
        s = LinkMetadata.decodeEntities(s)
        // Tidy whitespace: no trailing spaces except Markdown line breaks, at most one blank line.
        let lines = s.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            return trimmed.hasSuffix("  ") ? trimmed : trimmed.trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Words per minute for "12 min read".
    public static func readingMinutes(_ text: String) -> Double {
        Double(text.split(whereSeparator: \.isWhitespace).count) / 230
    }
}
