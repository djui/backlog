import AppKit
import UniformTypeIdentifiers

/// "Share → BackLog" from Safari, Chrome, Messages, WhatsApp and anywhere else that shares links or
/// text. Hands the link (and any text that came with it, as the note) to the app and closes.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: .zero) }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await share() }
    }

    private func share() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var url: URL?
        var texts: [String] = []
        for item in items {
            if let t = item.attributedContentText?.string, !t.isEmpty { texts.append(t) }
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let u = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !u.isFileURL {
                    url = u
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let t = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    texts.append(t)
                }
            }
        }
        let text = ([url?.absoluteString].compactMap { $0 } + texts).joined(separator: "\n")
        var components = URLComponents()
        components.scheme = "backlog"
        components.host = "add"
        let source = extensionContext.flatMap { _ in NSWorkspace.shared.frontmostApplication?.localizedName } ?? ""
        components.queryItems = [URLQueryItem(name: "url", value: text), URLQueryItem(name: "from", value: source)]
        if let open = components.url { NSWorkspace.shared.open(open) }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
