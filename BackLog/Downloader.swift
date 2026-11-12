import BackLogCore
import Foundation
import Observation
import SwiftData

/// What's happening to an item's files on this Mac right now.
enum DownloadStatus: Equatable {
    case idle
    case queued
    case fetchingInfo
    case downloading(fraction: Double?, bytesPerSecond: Double?)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .queued, .fetchingInfo, .downloading: true
        default: false
        }
    }
}

/// Fetches metadata and media for items, two at a time.
@MainActor @Observable
final class Downloader {
    private(set) var status: [UUID: DownloadStatus] = [:]
    var quality: DownloadQuality = .small
    var maxConcurrent = 2
    /// Called when an item's files are complete, e.g. to summarize it.
    @ObservationIgnored var onFinished: ((Item) -> Void)?

    @ObservationIgnored private var waiting: [PersistentIdentifier] = []
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func status(of item: Item) -> DownloadStatus { status[item.id] ?? .idle }

    var activeCount: Int { status.values.filter(\.isActive).count }

    /// Queues an item: metadata for everything, media for videos and reels.
    func enqueue(_ item: Item) {
        guard !(status[item.id]?.isActive ?? false) else { return }
        status[item.id] = .queued
        waiting.append(item.persistentModelID)
        pump()
    }

    func cancel(_ item: Item) {
        running[item.id]?.cancel()
        waiting.removeAll { $0 == item.persistentModelID }
        status[item.id] = .idle
    }

    /// Re-queues items whose media is missing and that haven't been finished, e.g. after a restart.
    func resumePending(in context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        for item in items where !item.state.isFinished && item.kind.isPlayable && ItemFiles(id: item.id).media == nil {
            enqueue(item)
        }
    }

    private func pump() {
        while running.count < maxConcurrent, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let item = container.mainContext.model(for: id) as? Item else { continue }
            let itemID = item.id
            running[itemID] = Task { [weak self] in
                await self?.process(item)
                self?.running[itemID] = nil
                self?.pump()
            }
        }
    }

    private func process(_ item: Item) async {
        let id = item.id
        guard let url = item.url else { status[id] = .failed("Not a valid link"); return }
        guard item.kind.isPlayable else { status[id] = .idle; return }
        guard let ytdlp = Tools.ytdlp else {
            status[id] = .failed("yt-dlp not found — brew install yt-dlp ffmpeg")
            return
        }
        let files = ItemFiles(id: id)
        do {
            try files.create()
            status[id] = .fetchingInfo
            let json = try await Tools.run(ytdlp, YTDLP.metadataArguments(for: url))
            let meta = try JSONDecoder().decode(YTDLPMetadata.self, from: Data(json.utf8))
            apply(meta, to: item)
            status[id] = .downloading(fraction: nil, bytesPerSecond: nil)
            let args = YTDLP.downloadArguments(for: url, into: files.directory, quality: quality, ffmpeg: Tools.ffmpeg)
            _ = try await Tools.run(ytdlp, args) { line in
                guard let progress = YTDLP.parseProgress(line) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.status[id]?.isActive == true else { return }
                    self.status[id] = .downloading(fraction: progress.fraction, bytesPerSecond: progress.bytesPerSecond)
                }
            }
            guard files.media != nil else { status[id] = .failed("Finished, but no media file was written"); return }
            // Captions are a bonus: a failure here never fails the download.
            if files.subtitles.isEmpty {
                _ = try? await Tools.run(ytdlp, YTDLP.subtitleArguments(for: url, into: files.directory, language: meta.language))
            }
            status[id] = .idle
            onFinished?(item)
        } catch is CancellationError {
            status[id] = .idle
        } catch let failure as Tools.Failure {
            status[id] = .failed(YTDLP.friendlyError(failure.message))
        } catch {
            status[id] = .failed(error.localizedDescription)
        }
        try? container.mainContext.save()
    }

    private func apply(_ meta: YTDLPMetadata, to item: Item) {
        if !meta.title.isEmpty { item.title = meta.title }
        if !meta.author.isEmpty { item.author = meta.author }
        if let d = meta.duration { item.durationSeconds = d }
        if let t = meta.thumbnail { item.thumbnailURL = t }
        try? container.mainContext.save()
    }
}
