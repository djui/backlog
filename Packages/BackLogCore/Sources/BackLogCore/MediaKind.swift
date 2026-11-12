import Foundation

/// What a saved link points at. Decides how BackLog fetches it and how it is shown.
public enum MediaKind: String, Codable, CaseIterable, Sendable {
    /// A long-form video (YouTube, Vimeo, …). Downloaded with yt-dlp.
    case video
    /// A short vertical video (YouTube Shorts, Instagram Reels, TikTok). Downloaded when possible.
    case reel
    /// A web page to read. Saved as reader-mode Markdown.
    case article
    /// A discussion (Hacker News, Reddit). Saved as the linked article, not the comments.
    case thread
    /// Anything else: kept in the list and history, never downloaded.
    case link

    /// Whether yt-dlp should try to download this.
    public var isPlayable: Bool { self == .video || self == .reel }

    public var label: String {
        switch self {
        case .video: "Video"
        case .reel: "Reel"
        case .article: "Article"
        case .thread: "Thread"
        case .link: "Link"
        }
    }
}

public enum SourceClassifier {
    /// Classifies a URL by its host and path. Unknown http(s) pages are articles.
    public static func kind(for url: URL) -> MediaKind {
        let host = normalizedHost(url)
        let path = url.path.lowercased()
        switch host {
        case "youtube.com", "youtube-nocookie.com", "music.youtube.com":
            return path.hasPrefix("/shorts/") ? .reel : .video
        case "youtu.be", "vimeo.com", "player.vimeo.com", "dailymotion.com", "twitch.tv", "ted.com":
            return .video
        case "instagram.com":
            return (path.hasPrefix("/reel") || path.hasPrefix("/p/") || path.hasPrefix("/tv/")) ? .reel : .link
        case "tiktok.com", "vm.tiktok.com":
            return .reel
        case "news.ycombinator.com", "reddit.com", "old.reddit.com", "lobste.rs":
            return .thread
        case "x.com", "twitter.com", "facebook.com", "threads.net", "linkedin.com":
            return .link
        default:
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .link }
            return .article
        }
    }

    /// The host without `www.` or `m.`, lower-cased.
    public static func normalizedHost(_ url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        return host
    }

    /// Tracking parameters dropped from every URL.
    static let trackingParameters: Set<String> = ["si", "fbclid", "gclid", "igshid", "igsh", "feature", "ref", "ref_src", "mc_cid", "mc_eid", "pp"]

    /// A stable form of the URL for spotting duplicates: https, no tracking parameters, no fragment,
    /// youtu.be and Shorts links rewritten to youtube.com/watch?v=.
    public static func canonical(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let host = normalizedHost(url)
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        components.fragment = nil

        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.host = "www.youtube.com"
            components.path = "/watch"
            let time = components.queryItems?.first { $0.name == "t" }
            components.queryItems = [URLQueryItem(name: "v", value: id)] + (time.map { [$0] } ?? [])
        } else if host == "youtube.com", url.path.lowercased().hasPrefix("/shorts/") {
            let id = String(url.path.dropFirst("/shorts/".count))
            components.host = "www.youtube.com"
            components.path = "/watch"
            components.queryItems = [URLQueryItem(name: "v", value: id)]
        }

        // On these sites the query is only share tracking (igsh, stkn, mdxt, …, which change all
        // the time); the path alone names the post.
        let queryless = ["instagram.com", "tiktok.com", "vm.tiktok.com", "threads.net", "x.com", "twitter.com"]
        if queryless.contains(host) { components.queryItems = nil }
        // YouTube: only the video and the start time matter.
        if host == "youtube.com" || host == "youtu.be" {
            let kept = (components.queryItems ?? []).filter { ["v", "t", "list"].contains($0.name) }
            components.queryItems = kept.isEmpty ? nil : kept
        }

        if let items = components.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url ?? url
    }
}
