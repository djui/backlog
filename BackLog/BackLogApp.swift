import AppKit
import BackLogCore
import Sparkle
import SwiftData
import SwiftUI

@main
struct BackLogApp: App {
    let container: ModelContainer
    @State private var downloader: Downloader
    @State private var summarizer: Summarizer
    @State private var search = SearchIndex()
    private let storage: StorageManager
    /// Sparkle updates; only in signed release builds (debug builds aren't in the appcast).
    private let updater: SPUStandardUpdaterController? = {
        #if DEBUG
        return nil
        #else
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }()
    @State private var app: AppState

    init() {
        let container = Persistence.makeContainer()
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
        let storage = StorageManager(container: container, downloader: downloader)
        downloader.wantsMedia = { storage.wantsMedia($0) }
        Library.onChange = { storage.schedule() }
        self.storage = storage
        let app = AppState()
        _app = State(initialValue: app)
        QuickCapture.shared.onCapture = { text in
            let result = Library.add(text: text, sharedBy: "", context: container.mainContext, downloader: downloader)
            app.report(result)
            return result
        }
        QuickCapture.shared.registerHotKey()
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
                    Library.improveTitles(context: container.mainContext)
                    Recents.seed(from: container.mainContext)
                    backfillSearch()
                    await ToolManager.shared.ensure()
                    downloader.resumePending(in: container.mainContext)
                    Task { await downloader.analyzeMissing(in: container.mainContext) }
                    summarizer.summarizeMissing()
                    async let rules: Void = storage.runPeriodically()
                    async let model: Void = summarizer.watchAvailability()
                    _ = await (rules, model)
                }
                .onOpenURL(perform: handle)
        }
        .defaultSize(width: 1360, height: 820)
        .modelContainer(container)
        .commands {
            ItemMenuCommands(app: app)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater?.checkForUpdates(nil) }
                    .disabled(updater == nil)
            }
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

        Settings {
            SettingsView()
                .modelContainer(container)
        }

        MenuBarExtra("BackLog", systemImage: "tray.full") {
            MenuBarContent()
                .environment(downloader)
                .environment(app)
                .modelContainer(container)
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
