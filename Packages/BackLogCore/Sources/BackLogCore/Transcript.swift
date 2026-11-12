import Foundation

/// One line of a transcript, starting at `start` seconds.
public struct TranscriptLine: Equatable, Codable, Sendable, Identifiable {
    public var start: Double
    public var text: String
    public var id: Double { start }

    public init(start: Double, text: String) {
        self.start = start
        self.text = text
    }
}

public enum Transcript {
    /// Parses WebVTT into lines. YouTube's automatic captions repeat each line across two cues
    /// (rolling captions) and wrap words in timing tags; both are cleaned up here.
    public static func parseVTT(_ vtt: String) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var seen = Set<String>()
        var recent: [String] = []
        var cueStart: Double?
        for raw in vtt.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                cueStart = parseTimestamp(String(line.split(separator: " ").first ?? ""))
                continue
            }
            guard let start = cueStart else { continue }
            if line.isEmpty { cueStart = nil; continue }
            let text = clean(line)
            guard !text.isEmpty else { continue }
            // Rolling captions repeat the previous line at the top of the next cue.
            if recent.contains(text) { continue }
            recent.append(text)
            if recent.count > 3 { recent.removeFirst() }
            if seen.count > 5000 { seen.removeAll() }
            seen.insert(text)
            lines.append(TranscriptLine(start: start, text: text))
        }
        return lines
    }

    /// Joins lines into paragraphs of roughly `seconds` each, for reading and for the summarizer.
    public static func paragraphs(_ lines: [TranscriptLine], every seconds: Double = 30) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        for line in lines {
            if let last = result.last, line.start - last.start < seconds {
                result[result.count - 1].text += " " + line.text
            } else {
                result.append(line)
            }
        }
        return result
    }

    /// Text with `[m:ss]` markers, split into chunks of at most `maxCharacters` each.
    public static func chunks(_ lines: [TranscriptLine], maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for p in paragraphs(lines) {
            let entry = "[\(clock(p.start))] \(p.text)\n"
            if !current.isEmpty, current.count + entry.count > maxCharacters {
                chunks.append(current)
                current = ""
            }
            current += entry
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// WebVTT for lines that have only start times; each cue lasts until the next one.
    public static func vtt(_ lines: [TranscriptLine]) -> String {
        func stamp(_ s: Double) -> String {
            let ms = Int((max(0, s) * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var out = "WEBVTT\n"
        for (i, line) in lines.enumerated() {
            let end = i + 1 < lines.count ? lines[i + 1].start : line.start + 4
            out += "\n\(stamp(line.start)) --> \(stamp(max(end, line.start + 0.5)))\n\(line.text)\n"
        }
        return out
    }

    /// Plain text for search and export.
    public static func plainText(_ lines: [TranscriptLine]) -> String {
        lines.map(\.text).joined(separator: " ")
    }

    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "00:01:02.500" or "01:02.500" → seconds.
    static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func clean(_ line: String) -> String {
        var s = line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#39;": "'", "&quot;": "\""] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        if s.hasPrefix("NOTE") || s == "WEBVTT" || s.hasPrefix("Kind:") || s.hasPrefix("Language:") { return "" }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
