import BackLogCore
import Foundation
import SwiftData

/// Adding, finishing and removing items.
@MainActor
enum Library {
    enum AddResult { case added(Item), duplicate(Item), imported(added: Int, skipped: Int), noLink }

    /// Adds what's in `text` to the end of Up Next: one link (a URL, or a chat message with a link
    /// in it), or — when it holds several, like a pasted chat export — all of them, each dated when
    /// it was shared and credited to who shared it. A link already in the library is moved back
    /// into Up Next instead of added twice (single link) or skipped (import).
    @discardableResult
    static func add(text: String, sharedBy: String = "", context: ModelContext, downloader: Downloader) -> AddResult {
        let entries = ChatImport.parse(text)
        if entries.count > 1 || entries.first?.date != nil {
            return importAll(entries, source: sharedBy, context: context, downloader: downloader)
        }
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
        onChange?()
        return .added(item)
    }

    /// Adds several links at once, oldest first, keeping their share dates.
    static func importAll(_ entries: [ChatImport.Entry], source: String, context: ModelContext, downloader: Downloader) -> AddResult {
        let all = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        var known = Set(all.map(\.canonicalURL))
        var next = (all.map(\.sortIndex).max() ?? 0) + 1
        var added: [Item] = []
        for entry in entries.sorted(by: { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }) {
            let canonical = SourceClassifier.canonical(entry.link.url).absoluteString
            guard known.insert(canonical).inserted else { continue }
            let item = Item(url: entry.link.url, kind: entry.link.kind, note: entry.link.note, sortIndex: next)
            next += 1
            if let date = entry.date { item.addedAt = date }
            item.sharedBy = [entry.sender, source.isEmpty ? nil : source].compactMap { $0 }.joined(separator: " · ")
            context.insert(item)
            added.append(item)
        }
        try? context.save()
        for item in added { downloader.enqueue(item) }
        onChange?()
        return .imported(added: added.count, skipped: entries.count - added.count)
    }

    /// Set by the app: re-applies the storage rules after changes.
    static var onChange: (() -> Void)?

    static func finish(_ item: Item, as state: ItemState = .done, context: ModelContext) {
        item.state = state
        try? context.save()
        onChange?()
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
        onChange?()
    }
}
