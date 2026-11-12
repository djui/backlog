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

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .link }
    var url: URL? { URL(string: urlString) }

    var state: ItemState {
        get { ItemState(rawValue: stateRaw) ?? .queued }
        set {
            stateRaw = newValue.rawValue
            consumedAt = newValue.isFinished ? (consumedAt ?? .now) : nil
        }
    }

    var durationText: String {
        guard durationSeconds > 0 else { return "" }
        let total = Int(durationSeconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum ItemState: String, Codable, CaseIterable {
    case queued, inProgress, done, skipped

    var isFinished: Bool { self == .done || self == .skipped }

    func label(for kind: MediaKind) -> String {
        switch self {
        case .queued: "Up next"
        case .inProgress: "In progress"
        case .done: kind.isPlayable ? "Watched" : "Read"
        case .skipped: "Skipped"
        }
    }
}
