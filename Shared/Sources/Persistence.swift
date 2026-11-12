import Foundation
import SwiftData

/// The library store, synced through iCloud (CloudKit, private database) between Mac and iPhone.
/// Only the list syncs — titles, notes, states, summaries; downloaded files stay on each device.
enum Persistence {
    static let cloudContainer = "iCloud.com.djui.BackLog"

    /// Debug builds sync with CloudKit's development environment, releases with production. They
    /// must never share a store: CloudKit sees two different histories, and Core Data answers
    /// "client knowledge differs from server knowledge" by wiping the local copy and reloading it
    /// from whichever environment the running build uses.
    static var storeURL: URL {
        #if DEBUG
        let name = "Library-Development.store"
        #else
        let name = "Library.store"
        #endif
        return ItemFiles.root.deletingLastPathComponent().appending(path: name)
    }

    static func makeContainer() -> ModelContainer {
        let schema = Schema([Item.self])
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        migrateDefaultStore()
        let synced = ModelConfiguration("BackLog", schema: schema, url: storeURL, cloudKitDatabase: .private(cloudContainer))
        if let container = try? ModelContainer(for: schema, configurations: synced) { return container }
        // No iCloud (signed out, or a build without the entitlement): same store, local only.
        let local = ModelConfiguration("BackLog", schema: schema, url: storeURL, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: local)
        } catch {
            fatalError("Couldn't open the library: \(error)")
        }
    }

    /// Early Mac builds used SwiftData's default store; move it to BackLog's own folder once.
    private static func migrateDefaultStore() {
        #if os(macOS) && !DEBUG
        let fm = FileManager.default
        guard !fm.fileExists(atPath: storeURL.path) else { return }
        let old = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "default.store")
        guard fm.fileExists(atPath: old.path) else { return }
        for suffix in ["", "-shm", "-wal"] {
            let from = URL(fileURLWithPath: old.path + suffix), to = URL(fileURLWithPath: storeURL.path + suffix)
            if fm.fileExists(atPath: from.path) { try? fm.copyItem(at: from, to: to) }
        }
        #endif
    }
}
