import BackLogCore
import Foundation
import SwiftData

/// Adding, finishing and removing items.
@MainActor
enum Library {
    enum AddResult { case added(Item), duplicate(Item), noLink }

    /// Adds the first link found in `text` (a URL or a whole chat message) to the end of Up Next.
    /// A link that's already in the library is moved back into Up Next instead of added twice.
    @discardableResult
    static func add(text: String, sharedBy: String = "", context: ModelContext, downloader: Downloader) -> AddResult {
        guard let link = SharedLink.parse(text) else { return .noLink }
        let canonical = SourceClassifier.canonical(link.url).absoluteString
        let all = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        if let existing = all.first(where: { $0.canonicalURL == canonical }) {
            if existing.state.isFinished { existing.state = .queued }
            if !link.note.isEmpty, existing.note.isEmpty { existing.note = link.note }
            try? context.save()
            downloader.enqueue(existing)
            return .duplicate(existing)
        }
        let last = all.map(\.sortIndex).max() ?? 0
        let item = Item(url: link.url, kind: link.kind, note: link.note, sortIndex: last + 1)
        item.sharedBy = sharedBy
        context.insert(item)
        try? context.save()
        downloader.enqueue(item)
        return .added(item)
    }

    static func finish(_ item: Item, as state: ItemState = .done, context: ModelContext) {
        item.state = state
        try? context.save()
    }

    /// Removes the item from the library entirely, files included.
    static func delete(_ item: Item, context: ModelContext, downloader: Downloader) {
        downloader.cancel(item)
        ItemFiles(id: item.id).deleteAll()
        context.delete(item)
        try? context.save()
    }

    /// Moves an item in Up Next by giving it a sort index between its new neighbours.
    static func move(_ items: [Item], from source: IndexSet, to destination: Int, context: ModelContext) {
        var ordered = items
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, item) in ordered.enumerated() { item.sortIndex = Double(i) }
        try? context.save()
    }
}
