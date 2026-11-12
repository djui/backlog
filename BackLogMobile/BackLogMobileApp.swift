import BackLogCore
import SwiftData
import SwiftUI

@main
struct BackLogMobileApp: App {
    let container: ModelContainer
    @State private var downloader: Downloader
    @State private var summarizer: Summarizer
    @State private var search: SearchIndex
    @State private var app = AppState()
    private let storage: StorageManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container = Persistence.makeContainer()
        self.container = container
        let downloader = Downloader(container: container)
        let summarizer = Summarizer(container: container)
        let search = SearchIndex()
        let storage = StorageManager(container: container, downloader: downloader)
        downloader.search = search
        downloader.onFinished = { summarizer.summarize($0) }
        downloader.wantsMedia = { _ in false }  // Videos play in their own apps on iPhone.
        summarizer.onSummarized = { item in
            item.rebuildSearchText(extra: SearchIndex.extraText(for: item))
            search.index(item)
        }
        Library.onChange = { storage.schedule() }
        _downloader = State(initialValue: downloader)
        _summarizer = State(initialValue: summarizer)
        _search = State(initialValue: search)
        self.storage = storage
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(downloader)
                .environment(summarizer)
                .environment(search)
                .environment(app)
                .tint(.orange)
                .onOpenURL(perform: handle)
                .task {
                    importInbox()
                    Library.improveTitles(context: container.mainContext)
                    downloader.resumePending(in: container.mainContext)
                    captureArticlesForOffline()
                    search.indexMissing((try? container.mainContext.fetch(FetchDescriptor<Item>())) ?? [])
                    summarizer.summarizeMissing()
                    await summarizer.watchAvailability()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        importInbox()
                        captureArticlesForOffline()
                        storage.schedule()
                    }
                }
        }
        .modelContainer(container)
    }

    /// Links shared from other apps while BackLog was closed.
    private func importInbox() {
        for entry in SharedInbox.drain() {
            let text = entry.note.isEmpty ? entry.text : entry.text + "\n" + entry.note
            let result = Library.add(text: text, sharedBy: entry.from, context: container.mainContext, downloader: downloader)
            app.report(result)
        }
    }

    /// Articles in Up Next are kept readable offline on this iPhone too (they're small); synced
    /// items arrive with their details but without the page.
    private func captureArticlesForOffline() {
        let items = (try? container.mainContext.fetch(FetchDescriptor<Item>())) ?? []
        let queue = items.filter { !$0.state.isFinished && ($0.kind == .article || $0.kind == .thread) }
            .sorted { $0.sortIndex < $1.sortIndex }
            .prefix(Preferences.shared.policy.downloadAhead * 4)
        for item in queue where !ItemFiles(id: item.id).hasArticle { downloader.enqueue(item) }
    }

    private func handle(_ url: URL) {
        guard url.scheme == "backlog", url.host == "add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let link = items.first(where: { $0.name == "url" })?.value else { return }
        let from = items.first { $0.name == "from" }?.value ?? ""
        app.report(Library.add(text: link, sharedBy: from, context: container.mainContext, downloader: downloader))
    }
}
