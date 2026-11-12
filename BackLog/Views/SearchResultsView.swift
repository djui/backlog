import BackLogCore
import SwiftUI

/// Results across everything — Up Next and all of History — by words and by meaning.
struct SearchResultsView: View {
    let query: String
    let items: [Item]
    @Binding var selection: Set<UUID>
    @Environment(SearchIndex.self) private var search
    @Environment(Downloader.self) private var downloader
    @Environment(AppState.self) private var app
    @State private var hits: [SearchIndex.Hit] = []
    @State private var kind: MediaKind?

    var body: some View {
        let shown = kind.map { k in hits.filter { $0.item.kind == k } } ?? hits
        List(selection: $selection) {
            ForEach(shown) { hit in
                VStack(alignment: .leading, spacing: 4) {
                    ItemRow(item: hit.item, status: downloader.status(of: hit.item))
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .padding(.leading, 140)
                    }
                }
                .tag(hit.item.id)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            ItemContextMenu(items: items.filter { ids.contains($0.id) }) { command in
                app.selected = ids
                app.command = command
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle("\(shown.count) result\(shown.count == 1 ? "" : "s") for “\(query)”")
        .safeAreaInset(edge: .top) {
            Picker("Kind", selection: $kind) {
                Text("All").tag(MediaKind?.none)
                ForEach(MediaKind.allCases, id: \.self) { Text($0.label + "s").tag(MediaKind?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .overlay {
            if shown.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(150))
            hits = search.search(query, in: items)
        }
    }
}
