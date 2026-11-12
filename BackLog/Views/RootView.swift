import BackLogCore
import SwiftData
import SwiftUI

enum LibrarySection: String, Hashable, CaseIterable, Identifiable {
    case upNext, downloading, history
    var id: Self { self }

    var title: String {
        switch self {
        case .upNext: "Up Next"
        case .downloading: "Downloading"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .upNext: "list.bullet"
        case .downloading: "arrow.down.circle"
        case .history: "clock"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(Downloader.self) private var downloader
    @Environment(AppState.self) private var app
    @Query(sort: \Item.sortIndex) private var items: [Item]
    @State private var section: LibrarySection? = .upNext
    @FocusState private var searchFocused: Bool
    @State private var pendingRemoval: [Item] = []

    private func perform(_ command: ItemCommand, on targets: [Item]) {
        BatchActions.perform(command, on: targets, context: context, downloader: downloader)
        if command == .remove { app.selected = [] }
    }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $section) {
                Section("Library") {
                    ForEach(LibrarySection.allCases) { s in
                        Label(s.title, systemImage: s.symbol)
                            .badge(count(for: s))
                            .tag(s)
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
                    ItemListView(section: section ?? .upNext, items: items, selection: $app.selected)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { app.showAddSheet = true } label: { Label("Add Link", systemImage: "plus") }
                    .help("Add a link (⌘N)")
            }
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search titles, captions, pictures, transcripts…")
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
            section = LibrarySection.allCases[index]
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
