import BackLogCore
import CoreData
import Foundation
import Observation
import SwiftData

/// User settings, kept in UserDefaults.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var policy: StoragePolicy {
        didSet { save(policy, "storagePolicy") }
    }
    /// Folder the History export is written to (e.g. LifeLog's sources folder); nil = off.
    var exportFolder: URL? {
        didSet { defaults.set(exportFolder?.path, forKey: "exportFolder") }
    }
    var autoExport: Bool {
        didSet { defaults.set(autoExport, forKey: "autoExport") }
    }
    var lastExport: Date? {
        didSet { defaults.set(lastExport, forKey: "lastExport") }
    }

    private init() {
        #if os(iOS)
        let fallback = StoragePolicy.phone
        #else
        let fallback = StoragePolicy()
        #endif
        policy = (defaults.data(forKey: "storagePolicy")).flatMap { try? JSONDecoder().decode(StoragePolicy.self, from: $0) } ?? fallback
        exportFolder = defaults.string(forKey: "exportFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        autoExport = defaults.object(forKey: "autoExport") as? Bool ?? true
        lastExport = defaults.object(forKey: "lastExport") as? Date
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

/// Applies the storage rules: downloads what should be offline, frees what's no longer needed,
/// and keeps the History export current. Runs on launch, every 30 minutes and after changes.
@MainActor @Observable
final class StorageManager {
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let downloader: Downloader
    @ObservationIgnored private let prefs = Preferences.shared
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Videos between the Mac and the iPhone, through iCloud.
    let mediaCloud = MediaCloud()

    init(container: ModelContainer, downloader: Downloader) {
        self.container = container
        self.downloader = downloader
        mediaCloud.items = { (try? container.mainContext.fetch(FetchDescriptor<Item>())) ?? [] }
        #if os(macOS)
        mediaCloud.download = { item in
            let status = downloader.status(of: item)
            if !status.isActive, !Self.failed(status) { downloader.enqueue(item, media: true) }
        }
        #endif
        // The other device changed the library (on the Mac: the iPhone asked for a video).
        NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    /// Runs soon, coalescing bursts of changes.
    func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            run()
        }
    }

    func runPeriodically() async {
        while !Task.isCancelled {
            run()
            try? await Task.sleep(for: .seconds(30 * 60))
        }
    }

    func run() {
        let context = container.mainContext
        let items = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let candidates = items.map(Self.candidate)
        let policy = prefs.policy
        downloader.quality = policy.quality

        #if os(iOS)
        // The iPhone can't download videos itself: it asks the Mac for them (MediaCloud).
        let wanted = Set(policy.toDownload(candidates))
        for id in policy.toDelete(candidates) {
            ItemFiles(id: id).deleteMedia()
            if let item = byID[id], item.mediaWanted, !wanted.contains(id) { item.mediaWanted = false }
        }
        for id in wanted where byID[id]?.mediaWanted == false { byID[id]?.mediaWanted = true }
        if context.hasChanges { try? context.save() }
        #else
        for id in policy.toDelete(candidates) { ItemFiles(id: id).deleteMedia() }
        for id in policy.toDownload(candidates) {
            if let item = byID[id], !downloader.status(of: item).isActive, !Self.failed(downloader.status(of: item)) {
                downloader.enqueue(item, media: true)
            }
        }
        #endif
        mediaCloud.sync()
        if prefs.autoExport { exportHistory(items) }
    }

    #if os(iOS)
    /// The Download button: ask the Mac for it, and fetch it as soon as it's in iCloud.
    func requestDownload(_ item: Item) {
        mediaCloud.resetFailure(item)
        item.mediaWanted = true
        try? container.mainContext.save()
        mediaCloud.sync()
    }

    /// Frees this iPhone's copy and tells the Mac it may free the iCloud one.
    func removeDownload(_ item: Item) {
        ItemFiles(id: item.id).deleteMedia()
        item.mediaWanted = false
        try? container.mainContext.save()
        mediaCloud.sync()
    }
    #endif

    /// Whether the rules want this item's media now (Up Next position, mode).
    func wantsMedia(_ item: Item) -> Bool {
        let items = (try? container.mainContext.fetch(FetchDescriptor<Item>())) ?? []
        return prefs.policy.toDownload(items.map(Self.candidate)).contains(item.id)
    }

    @discardableResult
    func exportHistory(_ items: [Item]? = nil) -> Int {
        guard let folder = prefs.exportFolder else { return 0 }
        let all = items ?? ((try? container.mainContext.fetch(FetchDescriptor<Item>())) ?? [])
        let entries = all.filter(\.state.isFinished).map(Self.exportEntry)
        let written = (try? HistoryExport.write(entries, to: folder)) ?? 0
        prefs.lastExport = .now
        return written
    }

    static func candidate(_ item: Item) -> StoragePolicy.Candidate {
        let files = ItemFiles(id: item.id)
        let media = files.media
        let bytes = media.flatMap { try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize }.map(Int64.init) ?? 0
        return .init(id: item.id, isPlayable: item.kind.isPlayable, isFinished: item.state.isFinished, finishedAt: item.consumedAt,
                     addedAt: item.addedAt, lastPlayedPosition: item.position, sortIndex: item.sortIndex,
                     hasMedia: media != nil, mediaBytes: bytes, keep: item.starred)
    }

    static func exportEntry(_ item: Item) -> ExportEntry {
        let summary = item.summary
        return ExportEntry(
            id: item.id, url: item.urlString, title: item.title, type: item.kind.rawValue,
            status: item.state.label(for: item.kind).lowercased(), added: item.addedAt, consumed: item.consumedAt,
            author: item.author.nilIfEmpty, site: item.siteName.nilIfEmpty, published: item.publishedAt,
            durationMinutes: item.durationSeconds > 0 ? max(1, Int((item.durationSeconds / 60).rounded())) : nil,
            sharedBy: item.sharedBy.nilIfEmpty, note: item.note.nilIfEmpty, description: item.details.nilIfEmpty,
            takeaway: summary?.takeaway, keyPoints: summary?.keyPoints.map(\.text) ?? [])
    }

    private static func failed(_ s: DownloadStatus) -> Bool {
        if case .failed = s { return true }
        return false
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
