import BackLogCore
import Foundation
import SwiftData

extension Recents {
    /// Fills the lists from the library (newest first), so suggestions include everything ever used,
    /// also on a new device.
    @MainActor
    static func seed(from context: ModelContext) {
        let items = ((try? context.fetch(FetchDescriptor<Item>())) ?? []).sorted { $0.addedAt > $1.addedAt }
        var fromList = from, tagList = tags
        for item in items.reversed() {
            if !item.sharedBy.isEmpty { fromList = Suggestions.remember(item.sharedBy, in: fromList) }
            for tag in Tags.parse(item.note).reversed() { tagList = Suggestions.remember(tag, in: tagList, max: 60) }
        }
        // Keep the user's most recent picks first.
        defaults.set(Array(NSOrderedSet(array: from + fromList).array as? [String] ?? fromList).prefix(30).map { $0 }, forKey: "recentFrom")
        defaults.set(Array(NSOrderedSet(array: tags + tagList).array as? [String] ?? tagList).prefix(60).map { $0 }, forKey: "recentTags")
    }
}
