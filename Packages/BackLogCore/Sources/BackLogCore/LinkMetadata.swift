import Foundation

/// What a web page says about itself in its <head>: Open Graph, Twitter cards, plain meta tags.
public struct LinkMetadata: Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var imageURL: URL?
    public var siteName: String?
    public var author: String?
    public var type: String?
    public var publishedAt: Date?
    public var videoURL: URL?
    public var durationSeconds: Double?

    public init() {}

    /// Parses meta tags from HTML. Relative image URLs resolve against `baseURL`.
    public static func parse(html: String, baseURL: URL) -> LinkMetadata {
        // Only the head matters, and huge pages are slow to scan.
        let head: Substring = {
            if let end = html.range(of: "</head>", options: .caseInsensitive) { return html[..<end.lowerBound] }
            return html.prefix(300_000)
        }()
        var meta: [String: String] = [:]
        let tagPattern = try! NSRegularExpression(pattern: #"<meta\s+[^>]*>"#, options: [.caseInsensitive])
        let attrPattern = try! NSRegularExpression(pattern: #"([a-zA-Z:_-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#)
        let headString = String(head)
        let ns = headString as NSString
        for match in tagPattern.matches(in: headString, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            var attrs: [String: String] = [:]
            let tns = tag as NSString
            for a in attrPattern.matches(in: tag, range: NSRange(location: 0, length: tns.length)) {
                let name = tns.substring(with: a.range(at: 1)).lowercased()
                let value = [3, 4, 5].lazy.compactMap { i -> String? in
                    let r = a.range(at: i)
                    return r.location == NSNotFound ? nil : tns.substring(with: r)
                }.first ?? ""
                attrs[name] = value
            }
            guard let key = (attrs["property"] ?? attrs["name"] ?? attrs["itemprop"])?.lowercased(),
                  let content = attrs["content"], !content.isEmpty else { continue }
            if meta[key] == nil { meta[key] = decodeEntities(content) }
        }

        var m = LinkMetadata()
        m.title = meta["og:title"] ?? meta["twitter:title"] ?? titleTag(headString)
        m.description = meta["og:description"] ?? meta["twitter:description"] ?? meta["description"]
        m.siteName = meta["og:site_name"] ?? meta["application-name"]
        m.author = meta["article:author"].flatMap { $0.hasPrefix("http") ? nil : $0 } ?? meta["author"] ?? meta["twitter:creator"]
        m.type = meta["og:type"]
        if let image = meta["og:image:secure_url"] ?? meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"] ?? meta["thumbnailurl"] {
            m.imageURL = URL(string: image, relativeTo: baseURL)?.absoluteURL
        }
        if let video = meta["og:video:secure_url"] ?? meta["og:video"] ?? meta["og:video:url"] {
            m.videoURL = URL(string: video, relativeTo: baseURL)?.absoluteURL
        }
        if let d = meta["og:video:duration"] ?? meta["video:duration"], let seconds = Double(d) { m.durationSeconds = seconds }
        if let published = meta["article:published_time"] ?? meta["og:published_time"] ?? meta["date"] {
            m.publishedAt = ISO8601DateFormatter().date(from: published) ?? {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withFullDate]
                return f.date(from: String(published.prefix(10)))
            }()
        }
        m.title = m.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        m.description = m.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return m
    }

    static func titleTag(_ head: String) -> String? {
        guard let start = head.range(of: "<title", options: .caseInsensitive),
              let open = head.range(of: ">", range: start.upperBound..<head.endIndex),
              let end = head.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<head.endIndex) else { return nil }
        let t = decodeEntities(String(head[open.upperBound..<end.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#x27;": "'", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        let numeric = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in numeric.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = m.range(at: 1).length > 0
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

/// The few things needed from Hacker News: an item's title and the article it links to.
public enum HackerNews {
    /// The item id of a news.ycombinator.com/item?id= link.
    public static func itemID(from url: URL) -> Int? {
        guard SourceClassifier.normalizedHost(url) == "news.ycombinator.com" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value.flatMap(Int.init)
    }

    public static func apiURL(for id: Int) -> URL {
        URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!
    }

    public struct Item: Decodable, Sendable {
        public var title: String?
        public var url: String?
        public var by: String?
        public var text: String?
        public var time: Double?
        public var descendants: Int?
    }
}
