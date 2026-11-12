import Foundation

/// Where an item's files live on this Mac: ~/Library/Application Support/BackLog/Items/<id>/.
struct ItemFiles {
    let id: UUID

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "BackLog/Items", directoryHint: .isDirectory)
    }()

    var directory: URL { Self.root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    var thumbnail: URL { directory.appending(path: "thumb.jpg") }

    /// The downloaded video or audio, if there is one.
    var media: URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.first { $0.hasPrefix("media.") && ["mp4", "m4a", "mov", "m4v", "webm", "mkv", "mp3"].contains(($0 as NSString).pathExtension) }
            .map { directory.appending(path: $0) }
    }

    /// Subtitle files yt-dlp wrote (subs.en.vtt, …).
    var subtitles: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("subs.") && $0.hasSuffix(".vtt") }.sorted().map { directory.appending(path: $0) }
    }

    var sizeOnDisk: Int64 {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    func create() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    /// Deletes the media file only; thumbnail, subtitles and metadata stay for the history.
    func deleteMedia() { if let media { try? FileManager.default.removeItem(at: media) } }

    func deleteAll() { try? FileManager.default.removeItem(at: directory) }
}
