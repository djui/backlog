import BackLogCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ItemListView: View {
    let section: LibrarySection
    let items: [Item]
    @Binding var selection: Set<UUID>
    @Environment(\.modelContext) private var context
    @Environment(Downloader.self) private var downloader
    @Environment(AppState.self) private var app
    @AppStorage("lengthFilter") private var length: LengthFilter = .any
    @AppStorage("listSort") private var sort: ListSort = .manual

    private var shown: [Item] { Library.arrange(base, length: length, sort: sort) }

    private var base: [Item] {
        switch section {
        case .upNext:
            items.filter { !$0.state.isFinished }
        case .downloading:
            items.filter { s in
                switch downloader.status(of: s) {
                case .queued, .fetchingInfo, .downloading, .failed: true
                case .idle: false
                }
            }
        case .history:
            items.filter(\.state.isFinished).sorted { ($0.consumedAt ?? $0.addedAt) > ($1.consumedAt ?? $1.addedAt) }
        }
    }

    var body: some View {
        let shown = shown
        List(selection: $selection) {
            ForEach(shown) { item in
                ItemRow(item: item, status: downloader.status(of: item))
                    .tag(item.id)
            }
            .onMove(perform: section == .upNext && sort == .manual && length == .any ? { Library.move(shown, from: $0, to: $1, context: context) } : nil)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            ItemContextMenu(items: items.filter { ids.contains($0.id) }) { command in
                app.selected = ids
                app.command = command
            }
        }
        .navigationTitle(section.title)
        .navigationSubtitle(subtitle(shown))
        .toolbar {
            ToolbarItem {
                ListOptionsMenu(length: $length, sort: $sort)
            }
        }
        .overlay {
            if shown.isEmpty, length != .any, !base.isEmpty {
                ContentUnavailableView {
                    Label("Nothing \(length.label.lowercased())", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Show Any Length") { length = .any }
                }
            } else if shown.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: section.symbol,
                                       description: Text(section == .upNext ? "Paste a YouTube link (⌘V) or drop one here." : ""))
            }
        }
        .onPasteCommand(of: [.url, .plainText]) { providers in
            Task { await add(from: providers) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { app.report(Library.add(text: url.absoluteString, context: context, downloader: downloader)) }
            return !urls.isEmpty
        }
        .onDeleteCommand { app.command = .remove }
    }

    private var emptyTitle: String {
        switch section {
        case .upNext: "Nothing up next"
        case .downloading: "No downloads"
        case .history: "No history yet"
        }
    }

    private func subtitle(_ shown: [Item]) -> String {
        let total = shown.reduce(0) { $0 + $1.durationSeconds }
        let hours = Int(total) / 3600, minutes = Int(total) / 60 % 60
        let time = total > 0 ? (hours > 0 ? " · \(hours) h \(minutes) min" : " · \(minutes) min") : ""
        let filter = length == .any ? "" : " · \(length.label)"
        return "\(shown.count) item\(shown.count == 1 ? "" : "s")\(time)\(filter)"
    }

    private func add(from providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self), let url = try? await provider.loadURL() {
                app.report(Library.add(text: url.absoluteString, context: context, downloader: downloader))
            } else if provider.canLoadObject(ofClass: String.self), let text = try? await provider.loadString() {
                app.report(Library.add(text: text, context: context, downloader: downloader))
            }
        }
    }
}

private extension NSItemProvider {
    func loadURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { c in
            _ = loadObject(ofClass: URL.self) { url, error in error.map { c.resume(throwing: $0) } ?? c.resume(returning: url) }
        }
    }

    func loadString() async throws -> String? {
        try await withCheckedThrowingContinuation { c in
            _ = loadObject(ofClass: String.self) { s, error in error.map { c.resume(throwing: $0) } ?? c.resume(returning: s) }
        }
    }
}

struct ItemRow: View {
    let item: Item
    let status: DownloadStatus

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(item: item)
                .frame(width: 128, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    if !item.durationText.isEmpty {
                        Text(item.durationText)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.durationSeconds > 0, item.position > 0 {
                        GeometryReader { g in
                            Rectangle().fill(.orange).frame(width: g.size.width * min(1, item.position / item.durationSeconds), height: 3)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if item.starred { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                }
                Text([item.kind.label, item.author].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                StatusLine(item: item, status: status)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusLine: View {
    let item: Item
    let status: DownloadStatus

    var body: some View {
        switch status {
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(.secondary)
        case .fetchingInfo:
            Text("Reading details…").font(.caption).foregroundStyle(.secondary)
        case .downloading(let fraction, let speed):
            HStack(spacing: 6) {
                ProgressView(value: fraction ?? 0).frame(width: 90).controlSize(.small)
                Text(downloadText(fraction, speed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(1)
        case .idle:
            if item.state.isFinished {
                Text(item.state.label(for: item.kind) + (item.consumedAt.map { " " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            } else if ItemFiles(id: item.id).media != nil {
                Label("Offline", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            } else if ItemFiles(id: item.id).hasArticle {
                Label("Saved to read offline", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            } else if !item.kind.isPlayable {
                Text(item.capturedAt == nil ? "Reading details…" : "Link").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func downloadText(_ fraction: Double?, _ speed: Double?) -> String {
        var parts: [String] = []
        if let fraction { parts.append("\(Int(fraction * 100))%") }
        if let speed, speed > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s") }
        return parts.isEmpty ? "Downloading…" : parts.joined(separator: " · ")
    }
}

struct Thumbnail: View {
    let item: Item

    var body: some View {
        let local = ItemFiles(id: item.id).thumbnail
        if let image = NSImage(contentsOf: local) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if let url = URL(string: item.thumbnailURL), !item.thumbnailURL.isEmpty {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
        }
    }

    private var symbol: String { item.kind.symbol }
}

/// Length filter and sort order, one menu in the toolbar. Filled icon while filtering.
struct ListOptionsMenu: View {
    @Binding var length: LengthFilter
    @Binding var sort: ListSort

    var body: some View {
        Menu {
            Picker("Length", selection: $length) {
                ForEach(LengthFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Sort", selection: $sort) {
                ForEach(ListSort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter & Sort", systemImage: length == .any && sort == .manual ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter by length, sort by length or date")
    }
}
