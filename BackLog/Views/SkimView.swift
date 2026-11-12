import BackLogCore
import SwiftData
import SwiftUI

/// Up Next as summaries: read the gist, then watch it, keep only the notes, or skip it.
struct SkimView: View {
    let items: [Item]
    @Binding var selection: UUID?
    @Binding var section: LibrarySection?
    @Environment(\.modelContext) private var context
    @Environment(Summarizer.self) private var summarizer
    @AppStorage("skimLength") private var length: SummaryLength = .tldr

    private var queue: [Item] { items.filter { !$0.state.isFinished } }

    var body: some View {
        let queue = queue
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("Read the gist, then decide. J/K to move, W to watch, N to keep notes only, X to skip.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(queue) { item in
                        SkimCard(item: item, length: length, isSelected: selection == item.id,
                                 watch: { watch(item) }, notesOnly: { notesOnly(item) }, skip: { skip(item) })
                            .id(item.id)
                            .onTapGesture { selection = item.id }
                    }
                }
                .padding(16)
            }
            .onChange(of: selection) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
        }
        .navigationTitle("Skim")
        .toolbar {
            ToolbarItem {
                Picker("Length", selection: $length) {
                    ForEach(SummaryLength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .overlay {
            if queue.isEmpty { ContentUnavailableView("Nothing to skim", systemImage: "text.alignleft") }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(characters: .init(charactersIn: "jkwnx")) { press in
            handle(press.characters, queue: queue)
            return .handled
        }
        .onAppear { if selection == nil || !queue.contains(where: { $0.id == selection }) { selection = queue.first?.id } }
    }

    private func handle(_ key: String, queue: [Item]) {
        let index = queue.firstIndex { $0.id == selection }
        switch key {
        case "j": selection = queue[min((index ?? -1) + 1, queue.count - 1)].id
        case "k": selection = queue[max((index ?? 1) - 1, 0)].id
        default:
            guard let index else { return }
            let item = queue[index]
            let next = queue.indices.contains(index + 1) ? queue[index + 1].id : (index > 0 ? queue[index - 1].id : nil)
            switch key {
            case "w": watch(item)
            case "n": notesOnly(item); selection = next
            case "x": skip(item); selection = next
            default: break
            }
        }
    }

    private func watch(_ item: Item) {
        selection = item.id
        section = .upNext
    }

    /// Keeps the summary and transcript, frees the video file, and moves it to History.
    private func notesOnly(_ item: Item) {
        ItemFiles(id: item.id).deleteMedia()
        Library.finish(item, as: .skimmed, context: context)
    }

    private func skip(_ item: Item) {
        Library.finish(item, as: .skipped, context: context)
    }
}

private struct SkimCard: View {
    let item: Item
    let length: SummaryLength
    let isSelected: Bool
    let watch: () -> Void
    let notesOnly: () -> Void
    let skip: () -> Void
    @Environment(Summarizer.self) private var summarizer

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Thumbnail(item: item)
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.headline).lineLimit(2)
                Text([item.kind.label, item.author, item.durationText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let summary = item.summary {
                    Text(summary.takeaway).font(.body.weight(.medium)).textSelection(.enabled)
                    ForEach(summary.points(for: length)) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(point.text).font(.callout)
                        }
                    }
                } else {
                    Text(placeholder).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Watch", action: watch).buttonStyle(.borderedProminent)
                    if ItemFiles(id: item.id).media != nil {
                        Button("Keep Notes, Delete Video", action: notesOnly)
                    }
                    Button("Skip", action: skip)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Color.orange : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1))
    }

    private var placeholder: String {
        switch summarizer.status(of: item) {
        case .working(let m): m
        case .failed(let m): m
        case .idle: item.kind.isPlayable ? "Summary appears once it's downloaded with captions." : "No summary yet."
        }
    }
}
