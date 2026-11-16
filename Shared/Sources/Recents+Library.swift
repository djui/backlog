import BackLogCore
import CoreData
import Foundation
import SwiftData

extension Recents {
    /// Fills the lists from the library (newest first), so suggestions include everything ever used,
    /// also on a new device. Tags no item has anymore (renamed or removed, maybe on the other
    /// device) are dropped; "From" names are kept, they're still worth suggesting.
    @MainActor
    static func seed(from context: ModelContext) {
        let items = ((try? context.fetch(FetchDescriptor<Item>())) ?? []).sorted { $0.addedAt > $1.addedAt }
        var fromList = from
        for item in items.reversed() where !item.sharedBy.isEmpty {
            fromList = Suggestions.remember(item.sharedBy, in: fromList)
        }
        // Keep the user's most recent picks first.
        defaults.set(Array(NSOrderedSet(array: from + fromList).array as? [String] ?? fromList).prefix(30).map { $0 }, forKey: "recentFrom")
        defaults.set(Suggestions.tags(recent: tags, inUse: items.flatMap(\.tags)), forKey: "recentTags")
    }

    @MainActor private static var pendingSeed: Task<Void, Never>?
    @MainActor private static var following = false

    /// Seeds now, and again whenever the other device changes the library (coalescing bursts), so
    /// a tag renamed there stops being suggested here.
    @MainActor
    static func follow(_ container: ModelContainer) {
        seed(from: container.mainContext)
        guard !following else { return }
        following = true
        NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                pendingSeed?.cancel()
                pendingSeed = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    seed(from: container.mainContext)
                }
            }
        }
    }
}
