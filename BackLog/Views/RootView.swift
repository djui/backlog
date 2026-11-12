import BackLogCore
import SwiftData
import SwiftUI

enum LibrarySection: String, Hashable, CaseIterable, Identifiable {
    case upNext, starred, downloading, history
    var id: Self { self }

    var title: String {
        switch self {
        case .upNext: "Up Next"
        case .starred: "Starred"
        case .downloading: "Downloading"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .upNext: "list.bullet"
        case .starred: "star"
        case .downloading: "arrow.down.circle"
        case .history: "clock"
        }
    }
}

/// What the sidebar shows: a library section or a tag.
enum SidebarSelection: Hashable {
    case section(LibrarySection)
    case tag(String)
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(Downloader.self) private var downloader
    @Environment(AppState.self) private var app
    @Query(sort: \Item.sortIndex) private var items: [Item]
    @State private var sidebar: SidebarSelection? = .section(.upNext)
    private var section: LibrarySection? { if case .section(let s) = sidebar { s } else { nil } }
    private var selectedTag: String? { if case .tag(let t) = sidebar { t } else { nil } }

    /// Every tag in the library with how many items have it, most used first.
    private var tagCounts: [(String, Int)] {
        var counts: [String: (String, Int)] = [:]
        for item in items { for tag in item.tags { counts[tag.lowercased(), default: (tag, 0)].1 += 1 } }
        return counts.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lowercased() < $1.0.lowercased() }
    }
    @FocusState private var searchFocused: Bool
    @State private var pendingRemoval: [Item] = []
    @AppStorage("showPanel") private var showPanel = true

    private func perform(_ command: ItemCommand, on targets: [Item]) {
        BatchActions.perform(command, on: targets, context: context, downloader: downloader)
        if command == .remove { app.selected = [] }
    }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $sidebar) {
                Section("Library") {
                    ForEach(LibrarySection.allCases) { s in
                        Label(s.title, systemImage: s.symbol)
                            .badge(count(for: s))
                            .tag(SidebarSelection.section(s))
                    }
                }
                let tags = tagCounts
                if !tags.isEmpty {
                    Section("Tags") {
                        ForEach(tags, id: \.0) { tag, n in
                            Label(tag, systemImage: "number")
                                .badge(n)
                                .tag(SidebarSelection.tag(tag))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { StorageFooter(items: items) }
        } content: {
            Group {
                if !app.searchText.isEmpty {
                    SearchResultsView(query: app.searchText, items: items, selection: $app.selected)
                } else {
                    ItemListView(section: section ?? .upNext, tag: selectedTag, items: items, selection: $app.selected)
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 440)
        } detail: {
            if let id = app.selection, let item = items.first(where: { $0.id == id }) {
                DetailView(item: item).id(item.id)
            } else if app.selected.count > 1 {
                BatchPanel(items: items.filter { app.selected.contains($0.id) }) { app.command = $0 }
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "play.rectangle",
                                       description: Text("Paste a link with ⌘V, drop one here, or press ⌘N."))
            }
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            // Search, then the panel toggle as the last item on the right.
            DefaultToolbarItem(kind: .search, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { showPanel.toggle() } label: { Label("Summary & Transcript", systemImage: "sidebar.right") }
                    .help("Show or hide the summary and transcript (⌥⌘I)")
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .disabled(app.selection == nil)
            }
        }
        .searchFocused($searchFocused)
        .onChange(of: app.command) { _, command in
            guard let command else { return }
            app.command = nil
            let targets = items.filter { app.selected.contains($0.id) }
            if command == .remove, targets.count > 1 {
                pendingRemoval = targets
            } else {
                perform(command, on: targets)
            }
        }
        .onChange(of: app.requestedSection) { _, index in
            guard let index else { return }
            app.requestedSection = nil
            sidebar = .section(LibrarySection.allCases[index])
            app.searchText = ""
        }
        .confirmationDialog("Remove \(pendingRemoval.count) items from your library?", isPresented: Binding(
            get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } }
        )) {
            Button("Remove \(pendingRemoval.count) Items", role: .destructive) {
                perform(.remove, on: pendingRemoval)
                pendingRemoval = []
            }
        } message: {
            Text("Their downloads, notes and summaries are deleted too. To keep them in History, mark them as done instead.")
        }
        .onChange(of: app.focusSearch) { _, focus in
            if focus { searchFocused = true; app.focusSearch = false }
        }
        .sheet(isPresented: $app.showAddSheet) { AddLinkSheet() }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.toast)
    }

    private func count(for section: LibrarySection) -> Int {
        switch section {
        case .upNext: items.filter { !$0.state.isFinished }.count
        case .downloading: items.filter { downloader.status(of: $0).isActive }.count
        case .starred: items.filter(\.starred).count
        case .history: items.filter(\.state.isFinished).count
        }
    }
}

private struct StorageFooter: View {
    let items: [Item]
    @Environment(Downloader.self) private var downloader
    @State private var bytes: Int64 = 0

    var body: some View {
        Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on this Mac")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .task(id: "\(items.count)-\(downloader.activeCount)") {
                let ids = items.map(\.id)
                bytes = await Task.detached { ids.reduce(Int64(0)) { $0 + ItemFiles(id: $1).sizeOnDisk } }.value
            }
    }
}
