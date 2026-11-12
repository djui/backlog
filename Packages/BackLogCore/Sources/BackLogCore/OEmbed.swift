import Foundation

/// oEmbed: the public "describe this link" API of video sites. More reliable than their web pages,
/// which in the EU are often a cookie-consent page instead of the video.
public struct OEmbed: Decodable, Equatable, Sendable {
    public var title: String?
    public var authorName: String?
    public var thumbnailURL: String?

    enum CodingKeys: String, CodingKey {
        case title, authorName = "author_name", thumbnailURL = "thumbnail_url"
    }

    /// The oEmbed endpoint for a link, for the sites that have one.
    public static func endpoint(for url: URL) -> URL? {
        let host = SourceClassifier.normalizedHost(url)
        let base: String
        switch host {
        case "youtube.com", "youtu.be", "music.youtube.com": base = "https://www.youtube.com/oembed"
        case "vimeo.com", "player.vimeo.com": base = "https://vimeo.com/api/oembed.json"
        case "tiktok.com", "vm.tiktok.com": base = "https://www.tiktok.com/oembed"
        case "open.spotify.com": base = "https://open.spotify.com/oembed"
        default: return nil
        }
        var c = URLComponents(string: base)!
        c.queryItems = [URLQueryItem(name: "url", value: SourceClassifier.canonical(url).absoluteString), URLQueryItem(name: "format", value: "json")]
        return c.url
    }

    /// Whether a page title is a cookie-consent or sign-in wall rather than the content.
    public static func isWallTitle(_ title: String) -> Bool {
        let t = title.lowercased()
        return ["before you continue", "bevor sie zu youtube weitergehen", "avant d'accéder à youtube", "consent", "cookie", "sign in to continue", "log in • instagram", "login • instagram"]
            .contains { t.contains($0) }
    }
}
