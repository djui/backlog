import BackLogCore
import Foundation
import ImageIO

/// Downloads pages and images for items that aren't videos.
enum PageFetcher {
    static let safariAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    /// Social sites only put a post's caption and image in the page for link-preview crawlers.
    static let previewAgent = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    static func userAgent(for url: URL) -> String {
        let host = SourceClassifier.normalizedHost(url)
        let social = ["instagram.com", "tiktok.com", "facebook.com", "threads.net", "x.com", "twitter.com", "linkedin.com"]
        return social.contains(where: { host == $0 || host.hasSuffix("." + $0) }) ? previewAgent : safariAgent
    }

    /// The page's HTML and the URL it ended up at after redirects.
    static func html(_ url: URL) async throws -> (String, URL) {
        var request = URLRequest(url: url)
        request.setValue(userAgent(for: url), forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("en,de;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw Tools.Failure(message: "The page answered \(http.statusCode)")
        }
        let encoding: String.Encoding = (response.textEncodingName?.lowercased().contains("8859") ?? false) ? .isoLatin1 : .utf8
        let text = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        return (text, response.url ?? url)
    }

    /// Downloads an image to `destination`, converting it to JPEG.
    @discardableResult
    static func image(_ url: URL, to destination: URL, maxDimension: CGFloat = 1280) async -> Bool {
        var request = URLRequest(url: url)
        request.setValue(safariAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let jpeg = ImageTools.jpeg(from: data, maxDimension: maxDimension) else { return false }
        return (try? jpeg.write(to: destination)) != nil
    }

    static func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum ImageTools {
    /// Re-encodes any image data as a JPEG no larger than `maxDimension`.
    static func jpeg(from data: Data, maxDimension: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
