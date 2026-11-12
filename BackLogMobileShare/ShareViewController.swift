import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// WhatsApp, Messages, Safari… › Share › BackLog: a small sheet with the link, who it's from and a
/// note. Saved links wait in the shared inbox until BackLog is next opened.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            let (url, text) = await loadShared()
            let sheet = ShareSheet(link: url?.absoluteString ?? "", sharedText: text,
                                   save: { [weak self] entry in self?.save(entry) },
                                   cancel: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) })
            let host = UIHostingController(rootView: sheet)
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    private func save(_ entry: SharedInbox.Entry) {
        try? SharedInbox.add(entry)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func loadShared() async -> (URL?, String) {
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
        return (url, texts.joined(separator: "\n"))
    }
}

private struct ShareSheet: View {
    let link: String
    let sharedText: String
    let save: (SharedInbox.Entry) -> Void
    let cancel: () -> Void
    @State private var from = UserDefaults(suiteName: SharedInbox.group)?.string(forKey: "lastFrom") ?? ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(link.isEmpty ? sharedText : link).font(.callout).lineLimit(3).foregroundStyle(.secondary)
                }
                Section {
                    TextField("From (e.g. Anna · WhatsApp)", text: $from)
                    TextField("Note", text: $note, axis: .vertical).lineLimit(1...3)
                } footer: {
                    Text("It's in your Up Next the next time you open BackLog, and on your Mac.")
                }
            }
            .navigationTitle("Save to BackLog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel, action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        UserDefaults(suiteName: SharedInbox.group)?.set(from, forKey: "lastFrom")
                        let text = link.isEmpty ? sharedText : (sharedText.contains(link) ? sharedText : link + "\n" + sharedText)
                        save(.init(text: text, from: from, note: note, date: .now))
                    }
                    .disabled(link.isEmpty && sharedText.isEmpty)
                }
            }
        }
    }
}
