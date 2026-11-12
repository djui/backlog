import Foundation

/// Links shared to BackLog from other apps on iPhone (WhatsApp › Share › BackLog) wait here, in the
/// container the app and its share extension share, until the app is next in front and adds them.
enum SharedInbox {
    static let group = "group.com.djui.BackLog"

    struct Entry: Codable {
        var text: String
        var from: String
        var note: String
        var date: Date
    }

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Extension: saves one shared link.
    static func add(_ entry: Entry) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: folder.appending(path: "\(UUID().uuidString).json"), options: .atomic)
    }

    /// App: takes everything waiting, oldest first, and empties the inbox.
    static func drain() -> [Entry] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let entries = files.compactMap { url -> Entry? in
            defer { try? FileManager.default.removeItem(at: url) }
            return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        }
        return entries.sorted { $0.date < $1.date }
    }
}
