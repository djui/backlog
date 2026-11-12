import Foundation

/// When to download media, and when to free it again. The same rules run on the Mac and the
/// iPhone; the iPhone just uses smaller numbers.
public struct StoragePolicy: Codable, Equatable, Sendable {
    public enum AutoDownload: String, Codable, CaseIterable, Sendable {
        /// The next `downloadAhead` videos in Up Next, topped up as you watch.
        case upNext
        /// Everything as soon as it's added.
        case everything
        /// Only when you press Download.
        case manual
    }

    public var autoDownload: AutoDownload = .upNext
    public var downloadAhead: Int = 5
    public var quality: DownloadQuality = .small
    /// Days after watching before a video file is deleted; 0 = right away, nil = never.
    public var deleteWatchedAfterDays: Int? = 3
    /// Days an unwatched, untouched download is kept; nil = forever.
    public var deleteUntouchedAfterDays: Int? = 30
    /// Total size of downloads; when over, the oldest watched files go first, then the oldest untouched.
    public var limitBytes: Int64? = 50_000_000_000

    public init() {}

    /// The phone default: fewer, smaller downloads, freed sooner.
    public static var phone: StoragePolicy {
        var p = StoragePolicy()
        p.downloadAhead = 2
        p.deleteWatchedAfterDays = 0
        p.deleteUntouchedAfterDays = 14
        p.limitBytes = 5_000_000_000
        return p
    }

    /// A downloadable item as the rules see it.
    public struct Candidate: Equatable, Sendable {
        public var id: UUID
        public var isPlayable: Bool
        public var isFinished: Bool
        public var finishedAt: Date?
        public var addedAt: Date
        public var lastPlayedPosition: Double
        public var sortIndex: Double
        public var hasMedia: Bool
        public var mediaBytes: Int64
        public var keep: Bool

        public init(id: UUID, isPlayable: Bool, isFinished: Bool, finishedAt: Date?, addedAt: Date, lastPlayedPosition: Double,
                    sortIndex: Double, hasMedia: Bool, mediaBytes: Int64, keep: Bool = false) {
            self.id = id; self.isPlayable = isPlayable; self.isFinished = isFinished; self.finishedAt = finishedAt
            self.addedAt = addedAt; self.lastPlayedPosition = lastPlayedPosition; self.sortIndex = sortIndex
            self.hasMedia = hasMedia; self.mediaBytes = mediaBytes; self.keep = keep
        }
    }

    /// Items whose media should be downloaded now.
    public func toDownload(_ items: [Candidate]) -> [UUID] {
        let queue = items.filter { $0.isPlayable && !$0.isFinished }.sorted { $0.sortIndex < $1.sortIndex }
        switch autoDownload {
        case .manual: return []
        case .everything: return queue.filter { !$0.hasMedia }.map(\.id)
        case .upNext: return queue.prefix(max(0, downloadAhead)).filter { !$0.hasMedia }.map(\.id)
        }
    }

    /// Items whose media should be deleted now (the item itself stays, with its notes).
    public func toDelete(_ items: [Candidate], now: Date = .now) -> [UUID] {
        let day: TimeInterval = 86_400
        var delete = Set<UUID>()
        let withMedia = items.filter { $0.hasMedia && !$0.keep }
        for item in withMedia {
            if item.isFinished, let days = deleteWatchedAfterDays, let at = item.finishedAt, now.timeIntervalSince(at) >= Double(days) * day {
                delete.insert(item.id)
            }
            if !item.isFinished, item.lastPlayedPosition == 0, let days = deleteUntouchedAfterDays,
               now.timeIntervalSince(item.addedAt) >= Double(days) * day {
                delete.insert(item.id)
            }
        }
        if let limit = limitBytes {
            var total = withMedia.filter { !delete.contains($0.id) }.reduce(Int64(0)) { $0 + $1.mediaBytes }
            // Watched first (oldest finished first), then unwatched from the end of the queue.
            let watched = withMedia.filter { $0.isFinished && !delete.contains($0.id) }.sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
            let unwatched = withMedia.filter { !$0.isFinished && !delete.contains($0.id) }.sorted { $0.sortIndex > $1.sortIndex }
            for item in watched + unwatched where total > limit {
                delete.insert(item.id)
                total -= item.mediaBytes
            }
        }
        return items.filter { delete.contains($0.id) }.map(\.id)
    }
}
