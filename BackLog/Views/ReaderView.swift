import SwiftUI
import WebKit

/// The saved article, rendered offline in a clean reading layout that follows light/dark mode.
/// No page scripts run; links open in the browser.
struct ReaderSurface: NSViewRepresentable {
    let files: ItemFiles
    let title: String
    let byline: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        load(into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    private func load(into view: WKWebView) {
        guard let body = try? String(contentsOf: files.articleHTML, encoding: .utf8) else { return }
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        :root { color-scheme: light dark; }
        body { font: 18px/1.6 "New York", "Iowan Old Style", Georgia, serif; max-width: 680px; margin: 32px auto 80px; padding: 0 28px; color: CanvasText; background: transparent; }
        h1 { font-size: 32px; line-height: 1.2; margin: 0 0 8px; }
        .byline { font: 13px -apple-system, system-ui, sans-serif; color: GrayText; margin-bottom: 28px; }
        h2, h3 { line-height: 1.3; margin-top: 1.6em; }
        img, video, figure { max-width: 100%; height: auto; border-radius: 6px; }
        figure { margin: 1.5em 0; }
        figcaption { font: 13px -apple-system, system-ui, sans-serif; color: GrayText; }
        a { color: #d4692e; }
        pre, code { font: 14px ui-monospace, "SF Mono", Menlo, monospace; }
        pre { background: color-mix(in srgb, CanvasText 6%, transparent); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
        blockquote { margin: 1.2em 0; padding-left: 16px; border-left: 3px solid color-mix(in srgb, CanvasText 20%, transparent); color: color-mix(in srgb, CanvasText 80%, transparent); }
        table { border-collapse: collapse; } td, th { padding: 4px 8px; border-bottom: 1px solid color-mix(in srgb, CanvasText 12%, transparent); }
        </style></head><body>
        <h1>\(escape(title))</h1>\(byline.isEmpty ? "" : "<div class=\"byline\">\(escape(byline))</div>")
        \(body)
        </body></html>
        """
        let reader = files.directory.appending(path: "reader.html")
        try? page.write(to: reader, atomically: true, encoding: .utf8)
        view.loadFileURL(reader, allowingReadAccessTo: files.directory)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if url.isFileURL, url.fragment != nil { return .allow }
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
                return .cancel
            }
            return .allow
        }
    }
}
