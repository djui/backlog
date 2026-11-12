import BackLogCore
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
@MainActor
final class StorageManager {
    private let container: ModelContainer
    private let downloader: Downloader
    private let prefs = Preferences.shared
    private var pending: Task<Void, Never>?

    init(container: ModelContainer, downloader: Downloader) {
        self.container = container
        self.downloader = downloader
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

        for id in policy.toDelete(candidates) { ItemFiles(id: id).deleteMedia() }
        for id in policy.toDownload(candidates) {
            if let item = byID[id], !downloader.status(of: item).isActive, !Self.failed(downloader.status(of: item)) {
                downloader.enqueue(item, media: true)
            }
        }
        if prefs.autoExport { exportHistory(items) }
    }

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
