import BackLogCore
import Foundation

/// Recently used "From" names and tags, for suggestions while typing. Kept where the app and the
/// iPhone share extension both see them (the App Group); on the Mac, in BackLog's own defaults.
enum Recents {
    static let defaults = UserDefaults(suiteName: "group.com.djui.BackLog") ?? .standard

    /// Where links usually come from; shown after the names you've used.
    static let sourcePresets = ["WhatsApp", "Messages", "Instagram", "Safari", "Mail", "Signal", "Telegram", "Slack"]

    static var from: [String] { defaults.stringArray(forKey: "recentFrom") ?? [] }
    static var tags: [String] { defaults.stringArray(forKey: "recentTags") ?? [] }

    static func remember(from value: String) {
        defaults.set(Suggestions.remember(value, in: from), forKey: "recentFrom")
    }

    static func remember(tags values: [String]) {
        var list = tags
        for tag in values.reversed() { list = Suggestions.remember(tag, in: list, max: 60) }
        defaults.set(list, forKey: "recentTags")
    }
}
