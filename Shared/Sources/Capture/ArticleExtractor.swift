import BackLogCore
import Foundation
import WebKit

/// What Mozilla's Readability finds in a page.
struct ExtractedArticle: Decodable {
    var title: String?
    var byline: String?
    var content: String?
    var textContent: String?
    var excerpt: String?
    var siteName: String?
    var publishedTime: String?
    var lang: String?
}

/// Runs Readability over a page's HTML in an off-screen web view. The page's own scripts are
/// disabled; only Readability runs.
@MainActor
final class ArticleExtractor: NSObject, WKNavigationDelegate {
    private static let readability: String = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?

    static func extract(html: String, baseURL: URL) async throws -> ExtractedArticle? {
        try await ArticleExtractor().run(html: html, baseURL: baseURL)
    }

    private func run(html: String, baseURL: URL) async throws -> ExtractedArticle? {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        webView.navigationDelegate = self
        self.webView = webView
        defer { self.webView = nil }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            // Images and styles aren't needed to find the article text.
            let stripped = html.replacingOccurrences(of: #"<link[^>]+rel=["']?stylesheet[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            webView.loadHTMLString(stripped, baseURL: baseURL)
        }

        let script = Self.readability + """
        ;(function() {
          const article = new Readability(document.cloneNode(true), { charThreshold: 300 }).parse();
          return article ? JSON.stringify(article) : null;
        })();
        """
        guard let json = try await webView.evaluateJavaScript(script) as? String else { return nil }
        return try JSONDecoder().decode(ExtractedArticle.self, from: Data(json.utf8))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in loaded?.resume(); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in loaded?.resume(throwing: error); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in loaded?.resume(throwing: error); loaded = nil }
    }

    /// Only the initial HTML string loads; links and redirects inside it are refused.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.navigationType == .other ? .allow : .cancel
    }
}

/// Saves an extracted article for offline reading: article.html (with local images), article.md.
enum ArticleStore {
    static func save(_ article: ExtractedArticle, baseURL: URL, into files: ItemFiles) async throws {
        var html = article.content ?? ""
        let imagesDir = files.directory.appending(path: "images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        // Download up to 40 images and point the HTML at the local copies.
        let pattern = try NSRegularExpression(pattern: #"<img[^>]+src\s*=\s*"([^"]+)""#, options: .caseInsensitive)
        let ns = html as NSString
        var sources: [String] = []
        for m in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let src = ns.substring(with: m.range(at: 1))
            if !sources.contains(src), !src.hasPrefix("data:") { sources.append(src) }
        }
        for (i, src) in sources.prefix(40).enumerated() {
            guard let url = URL(string: LinkMetadata.decodeEntities(src), relativeTo: baseURL)?.absoluteURL else { continue }
            let name = "images/\(i).jpg"
            if await PageFetcher.image(url, to: files.directory.appending(path: name), maxDimension: 1600) {
                html = html.replacingOccurrences(of: "\"\(src)\"", with: "\"\(name)\"")
            }
        }
        // Readability keeps srcset; drop it so the local src wins.
        html = html.replacingOccurrences(of: #"\s(srcset|sizes)\s*=\s*"[^"]*""#, with: "", options: [.regularExpression, .caseInsensitive])
        try html.write(to: files.articleHTML, atomically: true, encoding: .utf8)

        var markdown = "# \(article.title ?? "")\n\n"
        if let byline = article.byline, !byline.isEmpty { markdown += "*\(byline)*\n\n" }
        markdown += MarkdownConverter.markdown(fromHTML: html)
        try markdown.write(to: files.articleMarkdown, atomically: true, encoding: .utf8)
    }
}
