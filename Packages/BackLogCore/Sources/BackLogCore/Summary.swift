import Foundation

/// How much of a summary to show.
public enum SummaryLength: Int, CaseIterable, Codable, Sendable, Identifiable {
    case tldr, keyPoints, detailed
    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .tldr: "TL;DR"
        case .keyPoints: "Key points"
        case .detailed: "Detailed"
        }
    }
}

/// A point in a summary, with where in the video (or article) it's made.
public struct SummaryPoint: Codable, Equatable, Sendable, Identifiable {
    public var seconds: Double?
    public var text: String
    public var id: String { "\(seconds ?? -1)-\(text)" }

    public init(seconds: Double?, text: String) {
        self.seconds = seconds
        self.text = text
    }
}

/// A summary at three lengths: the takeaway, the few key points, and every point in order.
public struct Summary: Codable, Equatable, Sendable {
    public var takeaway: String
    public var keyPoints: [SummaryPoint]
    public var allPoints: [SummaryPoint]
    /// Rough reading time of the source in minutes, for "saves 18 min".
    public var sourceMinutes: Double?

    public init(takeaway: String, keyPoints: [SummaryPoint], allPoints: [SummaryPoint], sourceMinutes: Double? = nil) {
        self.takeaway = takeaway
        self.keyPoints = keyPoints
        self.allPoints = allPoints
        self.sourceMinutes = sourceMinutes
    }

    public func points(for length: SummaryLength) -> [SummaryPoint] {
        switch length {
        case .tldr: []
        case .keyPoints: keyPoints
        case .detailed: allPoints.isEmpty ? keyPoints : allPoints
        }
    }

    /// "~40 s read".
    public func readingTime(for length: SummaryLength) -> String {
        let words = (takeaway + " " + points(for: length).map(\.text).joined(separator: " ")).split(separator: " ").count
        let seconds = max(5, Double(words) / 230 * 60)
        return seconds < 60 ? "~\(Int((seconds / 5).rounded() * 5)) s read" : "~\(Int((seconds / 60).rounded())) min read"
    }

    public var json: String {
        (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? ""
    }

    public init?(json: String) {
        guard !json.isEmpty, let s = try? JSONDecoder().decode(Summary.self, from: Data(json.utf8)) else { return nil }
        self = s
    }
}
