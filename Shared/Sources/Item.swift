import BackLogCore
import Foundation
import SwiftData

/// One saved link. Every property has a default so the store can sync through CloudKit later.
/// Whether the media file is on this Mac is not stored: it's a fact about this disk (`ItemFiles`).
@Model
final class Item {
    var id: UUID = UUID()
    var urlString: String = ""
    var canonicalURL: String = ""
    var kindRaw: String = MediaKind.link.rawValue
    var title: String = ""
    var author: String = ""
    var durationSeconds: Double = 0
    var thumbnailURL: String = ""
    /// Who shared it and how ("Anna · WhatsApp"), and the text that came with it.
    var sharedBy: String = ""
    var note: String = ""
    var addedAt: Date = Date.now
    var stateRaw: String = ItemState.queued.rawValue
    var consumedAt: Date?
    /// Playback position in seconds, or reading progress 0…1 for articles.
    var position: Double = 0
    var sortIndex: Double = 0
    /// `Summary` as JSON; empty until summarized.
    var summaryJSON: String = ""
    /// The page's or video's own description (a reel's caption, an article's excerpt).
    var details: String = ""
    var siteName: String = ""
    var publishedAt: Date?
    /// Text read from the preview image, and what's in it ("pasta, bowl, food").
    var imageText: String = ""
    var imageLabels: String = ""
    /// When the link's details were last fetched; nil until then.
    var capturedAt: Date?
    /// Everything searchable, lower-cased: title, author, details, note, image, summary, transcript start.
    var searchText: String = ""
    /// The transcript as JSON ([TranscriptLine]), so devices without the video (the iPhone) have it
    /// too. Written by the Mac from captions or its own transcription.
    var transcriptJSON: String = ""
    /// Starred items keep their downloads regardless of the storage rules.
    var starred: Bool = false

    init(url: URL, kind: MediaKind, note: String = "", sortIndex: Double) {
        id = UUID()
        urlString = url.absoluteString
        canonicalURL = SourceClassifier.canonical(url).absoluteString
        kindRaw = kind.rawValue
        title = url.absoluteString
        author = SourceClassifier.normalizedHost(url)
        self.note = note
        self.sortIndex = sortIndex
        addedAt = .now
    }

    var summary: Summary? { Summary(json: summaryJSON) }

    /// The transcript: from this device's caption files, else the synced copy.
    var transcript: [TranscriptLine] {
        let local = ItemFiles(id: id).transcript
        if !local.isEmpty { return local }
        guard !transcriptJSON.isEmpty, let lines = try? JSONDecoder().decode([TranscriptLine].self, from: Data(transcriptJSON.utf8)) else { return [] }
        return lines
    }

    /// Stores the local transcript in the synced field (capped well below CloudKit's record size).
    /// Returns whether anything changed.
    @discardableResult
    func syncTranscriptFromFiles() -> Bool {
        var lines = ItemFiles(id: id).transcript
        guard !lines.isEmpty else { return false }
        var json = (try? String(decoding: JSONEncoder().encode(lines), as: UTF8.self)) ?? ""
        while json.utf8.count > 300_000, lines.count > 10 {
            lines.removeLast(lines.count / 4)
            json = (try? String(decoding: JSONEncoder().encode(lines), as: UTF8.self)) ?? ""
        }
        guard json != transcriptJSON else { return false }
        transcriptJSON = json
        return true
    }

    /// The text that describes this item, for search and embeddings (without the full transcript).
    var describingText: String {
        var parts = [title, author, siteName, details, note, sharedBy, imageLabels, imageText]
        if let s = summary { parts.append(s.takeaway); parts += s.keyPoints.map(\.text) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func rebuildSearchText(extra: String = "") {
        searchText = (describingText + "\n" + urlString + "\n" + extra).lowercased()
    }

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .link }
    var url: URL? { URL(string: urlString) }

    var state: ItemState {
        get { ItemState(rawValue: stateRaw) ?? .queued }
        set {
            stateRaw = newValue.rawValue
            consumedAt = newValue.isFinished ? (consumedAt ?? .now) : nil
        }
    }

    /// "12:34" for videos, "12 min read" for pages.
    var durationText: String {
        guard durationSeconds > 0 else { return "" }
        if !kind.isTimed { return "\(max(1, Int((durationSeconds / 60).rounded()))) min read" }
        let total = Int(durationSeconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum ItemState: String, Codable, CaseIterable {
    case queued, inProgress, done, skimmed, skipped

    var isFinished: Bool { self == .done || self == .skimmed || self == .skipped }

    func label(for kind: MediaKind) -> String {
        switch self {
        case .queued: "Up next"
        case .inProgress: "In progress"
        case .done: kind.doneLabel
        case .skimmed: "Skimmed"
        case .skipped: "Skipped"
        }
    }
}
