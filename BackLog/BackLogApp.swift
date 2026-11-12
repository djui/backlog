import AppKit
import BackLogCore
import SwiftData
import SwiftUI

@main
struct BackLogApp: App {
    let container: ModelContainer
    @State private var downloader: Downloader
    @State private var summarizer: Summarizer
    @State private var search = SearchIndex()
    @State private var app = AppState()

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Item.self)
        } catch {
            fatalError("Couldn't open the library: \(error)")
        }
        self.container = container
        let downloader = Downloader(container: container)
        let summarizer = Summarizer(container: container)
        downloader.onFinished = { summarizer.summarize($0) }
        let search = SearchIndex()
        downloader.search = search
        summarizer.onSummarized = { item in
            item.rebuildSearchText(extra: SearchIndex.extraText(for: item))
            search.index(item)
        }
        _search = State(initialValue: search)
        _downloader = State(initialValue: downloader)
        _summarizer = State(initialValue: summarizer)
    }

    var body: some Scene {
        Window("BackLog", id: "main") {
            RootView()
                .environment(downloader)
                .environment(app)
                .environment(summarizer)
                .environment(search)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    backfillSearch()
                    downloader.resumePending(in: container.mainContext)
                    summarizer.summarizeMissing()
                    await summarizer.watchAvailability()
                }
                .onOpenURL(perform: handle)
        }
        .defaultSize(width: 1280, height: 800)
        .modelContainer(container)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Link…") { app.showAddSheet = true }
                    .keyboardShortcut("n")
                Button("Add Link from Clipboard") { addFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Search Library") { app.focusSearch = true }
                    .keyboardShortcut("f")
            }
        }
    }

    /// backlog://add?url=<url>&from=<who> — for bookmarklets, Shortcuts and the share extension.
    private func handle(_ url: URL) {
        guard url.scheme == "backlog", url.host == "add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let link = items.first(where: { $0.name == "url" })?.value else { return }
        let from = items.first { $0.name == "from" }?.value ?? ""
        let result = Library.add(text: link, sharedBy: from, context: container.mainContext, downloader: downloader)
        app.report(result)
    }

    /// Items saved before search existed (or before a field was added) get their search text and vectors.
    private func backfillSearch() {
        let items = (try? container.mainContext.fetch(FetchDescriptor<Item>())) ?? []
        for item in items where item.searchText.isEmpty {
            item.rebuildSearchText(extra: SearchIndex.extraText(for: item))
        }
        try? container.mainContext.save()
        search.indexMissing(items)
    }

    private func addFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        app.report(Library.add(text: text, context: container.mainContext, downloader: downloader))
    }
}

/// UI state shared between the menu commands and the window.
@MainActor @Observable
final class AppState {
    var showAddSheet = false
    var searchText = ""
    var focusSearch = false
    var selection: UUID?
    var toast: String?

    func report(_ result: Library.AddResult) {
        switch result {
        case .added(let item): selection = item.id; toast = "Added to Up Next"
        case .duplicate(let item): selection = item.id; toast = "Already in your library — moved to Up Next"
        case .noLink: toast = "No link found"
        }
        let message = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if self.toast == message { self.toast = nil }
        }
    }
}
