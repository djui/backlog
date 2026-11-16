import BackLogCore
import CloudKit
import Foundation
import Observation

/// Gets videos onto the iPhone, which can't download them itself (no yt-dlp there).
///
/// The iPhone marks the videos it wants (`Item.mediaWanted`, synced with the library). The Mac
/// downloads them as usual and uploads a copy to the private CloudKit database, in its own zone
/// next to the library's, cut into chunks. The iPhone fetches the copy and plays it offline. The
/// Mac removes the copy once the video is watched, removed or no longer wanted.
///
/// Records: `MediaChunk` "<item id>-<n>" (asset `data`) for every chunk, then `MediaFile`
/// "<item id>" (`fileName`, `bytes`, `chunks`) — written last, so it means the copy is complete.
@MainActor @Observable
final class MediaCloud {
    enum Status: Equatable {
        case idle
        case uploading(fraction: Double)
        case downloading(fraction: Double)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .uploading, .downloading: true
            default: false
            }
        }
    }

    private(set) var status: [UUID: Status] = [:]
    /// Items with a complete copy in iCloud, as of the last look.
    private(set) var available: Set<UUID> = []

    func status(of item: Item) -> Status { status[item.id] ?? .idle }

    static let chunkBytes = 50_000_000
    private static let zoneID = CKRecordZone.ID(zoneName: "Media", ownerName: CKCurrentUserDefaultName)

    /// Created lazily: CKContainer traps when the app has no iCloud entitlement.
    @ObservationIgnored private lazy var database = CKContainer(identifier: Persistence.cloudContainer).privateCloudDatabase
    @ObservationIgnored private var zoneReady = false
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var retry: Task<Void, Never>?

    #if os(macOS)
    /// Downloads a wanted video that isn't on this Mac yet.
    @ObservationIgnored var download: ((Item) -> Void)?
    #endif

    /// The library, fetched fresh for each run.
    @ObservationIgnored var items: (() -> [Item])?

    /// Looks at iCloud and moves what needs moving. Runs again when asked while busy.
    func sync() {
        guard Persistence.isSyncing, let items else { return }
        if syncing { syncAgain = true; return }
        syncing = true
        Task {
            defer { syncing = false }
            repeat {
                syncAgain = false
                await run(items())
            } while syncAgain
        }
    }

    private func run(_ items: [Item]) async {
        let inventory: [UUID: Entry]
        do { inventory = try await fetchInventory() } catch { return }
        available = Set(inventory.filter { $0.value.isComplete }.keys)
        #if os(macOS)
        await upload(items, inventory: inventory)
        #else
        await fetchWanted(items)
        #endif
    }

    // MARK: - What's in iCloud

    private struct Entry {
        var chunks = 0
        var isComplete = false
    }

    /// Every media record in the zone, without the assets themselves.
    private func fetchInventory() async throws -> [UUID: Entry] {
        try await ensureZone()
        var entries: [UUID: Entry] = [:]
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token, desiredKeys: ["item", "chunks"])
            for case let .success(modification) in changes.modificationResultsByID.values {
                let record = modification.record
                guard let id = (record["item"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
                var entry = entries[id] ?? Entry()
                if record.recordType == "MediaFile" {
                    entry.isComplete = true
                    entry.chunks = max(entry.chunks, record["chunks"] as? Int ?? 0)
                } else {
                    entry.chunks = max(entry.chunks, (Self.chunkIndex(record.recordID) ?? 0) + 1)
                }
                entries[id] = entry
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return entries
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        let result = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        for r in result.saveResults.values { _ = try r.get() }
        zoneReady = true
    }

    private static func fileID(_ id: UUID) -> CKRecord.ID { CKRecord.ID(recordName: id.uuidString, zoneID: zoneID) }
    private static func chunkID(_ id: UUID, _ n: Int) -> CKRecord.ID { CKRecord.ID(recordName: "\(id.uuidString)-\(n)", zoneID: zoneID) }
    private static func chunkIndex(_ recordID: CKRecord.ID) -> Int? {
        recordID.recordName.split(separator: "-").last.flatMap { Int($0) }
    }

    private static func friendly(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .quotaExceeded: return "iCloud is full"
        case .networkUnavailable, .networkFailure: return "No connection"
        case .notAuthenticated: return "Not signed in to iCloud"
        default: return ck.localizedDescription
        }
    }

    // MARK: - Mac: upload what the iPhone wants

    #if os(macOS)
    private func upload(_ items: [Item], inventory: [UUID: Entry]) async {
        var wanted = Set<UUID>()
        for item in items where item.mediaWanted && item.kind.isPlayable && !item.state.isFinished {
            wanted.insert(item.id)
            guard inventory[item.id]?.isComplete != true else { continue }
            guard let file = ItemFiles(id: item.id).media else { download?(item); continue }
            do {
                try await upload(item.id, file: file, replacing: inventory[item.id]?.chunks ?? 0)
                available.insert(item.id)
                status[item.id] = nil
            } catch {
                status[item.id] = .failed(Self.friendly(error))
            }
        }
        // Watched, deleted or no longer wanted: free the iCloud space.
        guard !items.isEmpty else { return }
        for (id, entry) in inventory where !wanted.contains(id) {
            try? await remove(id, chunks: entry.chunks)
            available.remove(id)
        }
    }

    private func upload(_ id: UUID, file: URL, replacing oldChunks: Int) async throws {
        if oldChunks > 0 { try await remove(id, chunks: oldChunks) }  // A half-finished earlier try.
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let scratch = FileManager.default.temporaryDirectory.appending(path: "BackLogUpload-\(id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        status[id] = .uploading(fraction: 0)
        var n = 0, sent = 0
        while let data = try handle.read(upToCount: Self.chunkBytes), !data.isEmpty {
            try Task.checkCancellation()
            let part = scratch.appending(path: "\(n)")
            try data.write(to: part)
            let record = CKRecord(recordType: "MediaChunk", recordID: Self.chunkID(id, n))
            record["item"] = id.uuidString
            record["data"] = CKAsset(fileURL: part)
            try await save(record)
            try? FileManager.default.removeItem(at: part)
            n += 1
            sent += data.count
            status[id] = .uploading(fraction: size > 0 ? Double(sent) / Double(size) : 0)
        }
        let record = CKRecord(recordType: "MediaFile", recordID: Self.fileID(id))
        record["item"] = id.uuidString
        record["fileName"] = file.lastPathComponent
        record["bytes"] = Int64(sent)
        record["chunks"] = n
        try await save(record)
    }

    private func save(_ record: CKRecord) async throws {
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        for r in result.saveResults.values { _ = try r.get() }
    }

    private func remove(_ id: UUID, chunks: Int) async throws {
        let ids = [Self.fileID(id)] + (0..<chunks).map { Self.chunkID(id, $0) }
        _ = try await database.modifyRecords(saving: [], deleting: ids)
    }
    #endif

    // MARK: - iPhone: fetch what it wants

    #if os(iOS)
    private func fetchWanted(_ items: [Item]) async {
        var waiting = 0
        for item in items where item.mediaWanted && item.kind.isPlayable && !item.state.isFinished && ItemFiles(id: item.id).media == nil {
            guard available.contains(item.id) else { waiting += 1; continue }
            if case .failed = status(of: item) { continue }  // Until Try Again.
            await fetch(item.id)
        }
        // The Mac may be working on them right now: look again in a minute while the app is open.
        retry?.cancel()
        if waiting > 0 {
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.sync()
            }
        }
    }

    /// Clears a failure so the next run tries again.
    func resetFailure(_ item: Item) { if case .failed = status(of: item) { status[item.id] = nil } }

    private func fetch(_ id: UUID) async {
        let files = ItemFiles(id: id)
        let partial = files.directory.appending(path: "media.partial")
        status[id] = .downloading(fraction: 0)
        let background = UIApplicationBackgroundTask.begin()
        defer { background.end() }
        do {
            try files.create()
            let file = try await database.record(for: Self.fileID(id))
            let chunks = file["chunks"] as? Int ?? 0
            let name = file["fileName"] as? String ?? "media.mp4"
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            for n in 0..<chunks {
                try Task.checkCancellation()
                let record = try await database.record(for: Self.chunkID(id, n))
                guard let url = (record["data"] as? CKAsset)?.fileURL else { throw CKError(.assetFileNotFound) }
                try handle.write(contentsOf: Data(contentsOf: url, options: .mappedIfSafe))
                status[id] = .downloading(fraction: Double(n + 1) / Double(max(chunks, 1)))
            }
            try handle.close()
            let target = files.directory.appending(path: name.hasPrefix("media.") ? name : "media.mp4")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            status[id] = nil
        } catch {
            try? FileManager.default.removeItem(at: partial)
            status[id] = .failed(Self.friendly(error))
        }
    }
    #endif
}

#if os(iOS)
import UIKit

/// A little extra time to finish a download when the app goes to the background.
@MainActor
private struct UIApplicationBackgroundTask {
    let id: UIBackgroundTaskIdentifier

    static func begin() -> Self {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "Download video") {
            UIApplication.shared.endBackgroundTask(id)
        }
        return Self(id: id)
    }

    func end() { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
}
#endif
