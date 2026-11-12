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

/// Captures items, two at a time: details and preview image for every link, the media for
/// videos and reels, the readable text for articles, then image analysis and the search index.
@MainActor @Observable
final class Downloader {
    private(set) var status: [UUID: DownloadStatus] = [:]
    var quality: DownloadQuality = .small
    var maxConcurrent = 2
    /// Called when an item's files are complete, e.g. to summarize it.
    @ObservationIgnored var onFinished: ((Item) -> Void)?
    @ObservationIgnored var search: SearchIndex?
    /// Decides whether an item's media is wanted now (the storage rules). Without it, always.
    @ObservationIgnored var wantsMedia: ((Item) -> Bool)?
    /// Items whose media was asked for explicitly or by the rules.
    @ObservationIgnored private var mediaRequested: Set<UUID> = []

    @ObservationIgnored private var waiting: [PersistentIdentifier] = []
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func status(of item: Item) -> DownloadStatus { status[item.id] ?? .idle }

    var activeCount: Int { status.values.filter(\.isActive).count }

    /// Queues an item for capture. `media: true` downloads its video even if the storage rules
    /// wouldn't (the Download button).
    func enqueue(_ item: Item, media: Bool = false) {
        if media { mediaRequested.insert(item.id) }
        guard !(status[item.id]?.isActive ?? false) else { return }
        status[item.id] = .queued
        waiting.append(item.persistentModelID)
        pump()
    }

    func cancel(_ item: Item) {
        mediaRequested.remove(item.id)
        running[item.id]?.cancel()
        waiting.removeAll { $0 == item.persistentModelID }
        status[item.id] = .idle
    }

    /// Re-queues what's missing after a restart: never-captured links, and media for unfinished videos.
    func resumePending(in context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        for item in items {
            if item.capturedAt == nil { enqueue(item) }
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
        let files = ItemFiles(id: id)
        try? files.create()
        status[id] = .fetchingInfo
        var failure: String?
        do {
            switch item.kind {
            case .video, .reel:
                #if os(macOS)
                failure = try await captureMedia(item, url: url, files: files)
                #else
                // On iPhone, videos open in their own apps; their details come from the page.
                try await capturePage(item, url: url, files: files)
                #endif
            case .article, .thread, .link:
                try await capturePage(item, url: url, files: files)
            }
        } catch is CancellationError {
            status[id] = .idle
            return
        } catch let error as ToolFailure {
            failure = YTDLP.friendlyError(error.message)
        } catch {
            failure = error.localizedDescription
        }
        await finishCapture(item, files: files)
        status[id] = failure.map { .failed($0) } ?? .idle
        if failure == nil { onFinished?(item) }
    }

    #if os(macOS)
    /// Videos and reels: yt-dlp for details and media. A reel yt-dlp can't get (sign-in walls)
    /// still gets its caption and image from the page. Returns a message when the media failed.
    private func captureMedia(_ item: Item, url: URL, files: ItemFiles) async throws -> String? {
        if Tools.ytdlp == nil { await ToolManager.shared.ensure() }
        guard let ytdlp = Tools.ytdlp else { return "Couldn't set up the video downloader — check your connection" }
        let meta: YTDLPMetadata
        do {
            let json = try await Tools.run(ytdlp, YTDLP.metadataArguments(for: url))
            meta = try JSONDecoder().decode(YTDLPMetadata.self, from: Data(json.utf8))
        } catch let error as ToolFailure {
            try await capturePage(item, url: url, files: files)
            return item.kind == .reel ? "Couldn't download — saved the caption and picture" : YTDLP.friendlyError(error.message)
        }
        apply(meta, to: item)
        let wanted = mediaRequested.contains(item.id) || (wantsMedia?(item) ?? true)
        mediaRequested.remove(item.id)
        guard wanted || files.media != nil else { return nil }  // Details only, for now.

        if files.media == nil {
            status[item.id] = .downloading(fraction: nil, bytesPerSecond: nil)
            let id = item.id
            let args = YTDLP.downloadArguments(for: url, into: files.directory, quality: quality, ffmpeg: Tools.ffmpeg)
            _ = try await Tools.run(ytdlp, args) { line in
                guard let progress = YTDLP.parseProgress(line) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.status[id]?.isActive == true else { return }
                    self.status[id] = .downloading(fraction: progress.fraction, bytesPerSecond: progress.bytesPerSecond)
                }
            }
            try await MediaJoiner.joinIfNeeded(in: files.directory)
            MediaJoiner.normalizeThumbnail(in: files.directory)
            guard files.media != nil else { return "Finished, but no media file was written" }
        }
        // Captions are a bonus: a failure here never fails the download.
        if files.subtitles.isEmpty, item.kind == .video {
            _ = try? await Tools.run(ytdlp, YTDLP.subtitleArguments(for: url, into: files.directory, language: meta.language))
        }
        return nil
    }

    #endif

    /// Pages: Open Graph details and preview image; the readable article for articles and the
    /// article a Hacker News thread links to.
    private func capturePage(_ item: Item, url: URL, files: ItemFiles) async throws {
        var pageURL = url
        if let hnID = HackerNews.itemID(from: url),
           let hn = try? await PageFetcher.json(HackerNews.Item.self, from: HackerNews.apiURL(for: hnID)) {
            if let t = hn.title { item.title = t }
            item.siteName = "Hacker News"
            if let by = hn.by { item.author = by }
            if let comments = hn.descendants { item.details = "\(comments) comments on Hacker News" }
            guard let linked = hn.url.flatMap(URL.init(string:)) else { item.capturedAt = .now; return }
            pageURL = linked
        }

        let (html, finalURL) = try await PageFetcher.html(pageURL)
        let meta = LinkMetadata.parse(html: html, baseURL: finalURL)
        let isThread = item.kind == .thread
        if let t = meta.title, !t.isEmpty, !isThread || item.title == item.urlString { item.title = t }
        if let d = meta.description, !d.isEmpty, !isThread { item.details = d }
        if let s = meta.siteName, !isThread { item.siteName = s }
        if let a = meta.author, !a.isEmpty, !isThread { item.author = a }
        if let p = meta.publishedAt { item.publishedAt = p }
        if let d = meta.durationSeconds, item.durationSeconds == 0 { item.durationSeconds = d }
        if let image = meta.imageURL, !FileManager.default.fileExists(atPath: files.thumbnail.path) {
            await PageFetcher.image(image, to: files.thumbnail)
            item.thumbnailURL = image.absoluteString
        }

        if item.kind == .article || isThread {
            if let article = try? await ArticleExtractor.extract(html: html, baseURL: finalURL),
               (article.textContent?.count ?? 0) > 400 {
                try? await ArticleStore.save(article, baseURL: finalURL, into: files)
                if let t = article.title, !t.isEmpty, !isThread { item.title = t }
                if let b = article.byline, !b.isEmpty, item.author.isEmpty || item.author == SourceClassifier.normalizedHost(url) { item.author = b }
                if item.details.isEmpty, let e = article.excerpt { item.details = e }
                if item.siteName.isEmpty, let s = article.siteName { item.siteName = s }
                // Reading time stands in for duration.
                item.durationSeconds = (MarkdownConverter.readingMinutes(article.textContent ?? "") * 60).rounded()
            }
        }
        item.capturedAt = .now
        try? container.mainContext.save()
    }

    /// After any capture: read the preview image, refresh search text and the semantic index.
    private func finishCapture(_ item: Item, files: ItemFiles) async {
        if item.capturedAt == nil { item.capturedAt = .now }
        if item.imageLabels.isEmpty, let result = await ImageAnalyzer.analyze(files.thumbnail) {
            item.imageText = result.text
            item.imageLabels = result.labels.joined(separator: ", ")
        }
        item.rebuildSearchText(extra: SearchIndex.extraText(for: item))
        try? container.mainContext.save()
        search?.index(item)
    }

    static let siteNames = ["youtube": "YouTube", "instagram": "Instagram", "tiktok": "TikTok", "vimeo": "Vimeo", "twitch": "Twitch", "ted": "TED", "dailymotion": "Dailymotion"]

    #if os(macOS)
    private func apply(_ meta: YTDLPMetadata, to item: Item) {
        if !meta.title.isEmpty { item.title = meta.title }
        if !meta.author.isEmpty { item.author = meta.author }
        if let d = meta.duration { item.durationSeconds = d }
        if let t = meta.thumbnail { item.thumbnailURL = t }
        if let d = meta.description, !d.isEmpty { item.details = String(d.prefix(4000)) }
        if let date = meta.uploadDate {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            item.publishedAt = f.date(from: date)
        }
        if let site = meta.extractor { item.siteName = Self.siteNames[site.lowercased()] ?? site }
        item.capturedAt = .now
        try? container.mainContext.save()
    }
    #endif
}
