import AVKit
import BackLogCore
import SwiftData
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary", transcript = "Transcript"
    var id: Self { self }
}

struct DetailView: View {
    @Bindable var item: Item
    @Environment(\.modelContext) private var context
    @Environment(Downloader.self) private var downloader
    @State private var player = PlayerController()
    @AppStorage("detailTab") private var tab: DetailTab = .summary
    @AppStorage("showPanel") private var showPanel = true

    var body: some View {
        let status = downloader.status(of: item)
        let files = ItemFiles(id: item.id)
        let media = files.media
        Group {
            if files.hasArticle {
                VStack(spacing: 0) {
                    ReaderSurface(files: files, title: item.title, byline: [item.author, item.siteName].filter { !$0.isEmpty }.joined(separator: " · "))
                        .id(item.id)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) { ItemActions(item: item, media: nil) }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                }
            } else {
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        if let media, !status.isActive {
                            PlayerSurface(player: player.player)
                                .onAppear { player.load(item, file: media, context: context) }
                                .onDisappear { player.unload() }
                        } else {
                            Thumbnail(item: item)
                                .overlay {
                                    if item.kind.isPlayable {
                                        VStack(spacing: 8) {
                                            StatusLine(item: item, status: status)
                                            if case .failed = status { Button("Try Again") { downloader.enqueue(item, media: true) } }
                                            else if !status.isActive { Button("Download") { downloader.enqueue(item, media: true) } }
                                        }
                                        .padding(12)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    ItemHeader(item: item, media: media)
                }
                .padding(20)

                }
            }
        }
        .inspector(isPresented: $showPanel) {
            VStack(spacing: 0) {
                let hasTranscript = !files.subtitles.isEmpty
                if hasTranscript {
                    Picker("Panel", selection: $tab) {
                        ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(12)
                    Divider()
                }
                switch hasTranscript ? tab : .summary {
                case .summary: SummaryPanel(item: item) { player.seek(to: $0) }
                case .transcript: TranscriptPanel(item: item, player: player)
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 300, max: 440)
        }
        .toolbar {
            ToolbarItem {
                Button { showPanel.toggle() } label: { Label("Summary & Transcript", systemImage: "sidebar.right") }
                    .help("Show or hide the summary and transcript (⌥⌘I)")
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

private struct ItemHeader: View {
    @Bindable var item: Item
    let media: URL?
    @State private var showAllDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.title2.bold()).textSelection(.enabled)
            Text(meta).foregroundStyle(.secondary)
            if !item.note.isEmpty || !item.sharedBy.isEmpty {
                Text([item.sharedBy, item.note].filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if !item.details.isEmpty {
                Text(item.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(showAllDetails ? nil : 4)
                    .textSelection(.enabled)
                    .onTapGesture { showAllDetails.toggle() }
            }
            if !item.imageLabels.isEmpty {
                Text("In the picture: \(item.imageLabels)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        ItemActions(item: item, media: media)
    }

    private var meta: String {
        var parts = [item.kind.label]
        if !item.siteName.isEmpty, item.siteName.lowercased() != item.author.lowercased() { parts.append(item.siteName) }
        if !item.author.isEmpty { parts.append(item.author) }
        if !item.durationText.isEmpty { parts.append(item.durationText) }
        if let p = item.publishedAt { parts.append(p.formatted(date: .abbreviated, time: .omitted)) }
        parts.append("added " + item.addedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

struct ItemActions: View {
    @Bindable var item: Item
    let media: URL?
    @Environment(\.modelContext) private var context

    /// Full labels when there's room; icons only (with tooltips) in a narrow window, instead of
    /// buttons squeezed to nothing.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if item.state.isFinished {
                action("Back to Up Next", "arrow.uturn.backward", compact) { item.state = .queued; try? context.save() }
            } else {
                action("Mark as \(item.kind.doneLabel)", "checkmark", compact) { Library.finish(item, context: context) }
                    .buttonStyle(.borderedProminent)
                action("Skip", "forward", compact) { Library.finish(item, as: .skipped, context: context) }
            }
            Button {
                item.starred.toggle()
                try? context.save()
            } label: {
                Label(item.starred ? "Unstar" : "Star", systemImage: item.starred ? "star.fill" : "star")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(item.starred ? .yellow : .secondary)
            }
            .help(item.starred ? "Unstar (⌥⌘S)" : "Star: keep the download and find it easily (⌥⌘S)")
            .fixedSize()
            Spacer(minLength: compact ? 8 : 16)
            if let url = item.url { action("Open Original", "safari", compact) { NSWorkspace.shared.open(url) } }
            if let media { action("Show in Finder", "folder", compact) { NSWorkspace.shared.activateFileViewerSelecting([media]) } }
        }
    }

    private func action(_ title: String, _ symbol: String, _ compact: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            if compact {
                Label(title, systemImage: symbol).labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: symbol).labelStyle(.titleOnly)
            }
        }
        .help(title)
        .fixedSize()
    }
}

/// The takeaway and points at the length you pick. Timestamps jump the player there.
struct SummaryPanel: View {
    let item: Item
    var compact = false
    let seek: (Double) -> Void
    @Environment(Summarizer.self) private var summarizer
    @AppStorage("summaryLength") private var length: SummaryLength = .keyPoints

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = item.summary {
                    HStack {
                        Picker("Length", selection: $length) {
                            ForEach(SummaryLength.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Text(summary.readingTime(for: length) + (summary.sourceMinutes.map { " · instead of \(Int($0.rounded())) min" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TAKEAWAY").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                        Text(summary.takeaway).font(.body.weight(.semibold)).textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    ForEach(summary.points(for: length)) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let s = point.seconds {
                                Button(Transcript.clock(s)) { seek(s) }
                                    .buttonStyle(.link)
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 48, alignment: .leading)
                            }
                            Text(point.text).font(.callout).textSelection(.enabled)
                        }
                    }
                    Text("Generated on this Mac from the transcript.").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    placeholder
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch summarizer.status(of: item) {
        case .working(let message):
            HStack { ProgressView().controlSize(.small); Text(message).foregroundStyle(.secondary) }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Try Again") { summarizer.summarize(item, force: true) }
            }
        case .idle:
            if ItemFiles(id: item.id).transcript.isEmpty {
                Text(item.kind.isPlayable ? "No captions for this video, so no summary." : "Summaries for this kind of item are coming.")
                    .foregroundStyle(.secondary)
            } else {
                Button("Summarize") { summarizer.summarize(item, force: true) }
            }
        }
    }
}

/// The transcript, following playback. Click a line to jump there.
struct TranscriptPanel: View {
    let item: Item
    let player: PlayerController
    @State private var lines: [TranscriptLine] = []
    @State private var query = ""

    var body: some View {
        let shown = query.isEmpty ? lines : lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
        let current = lines.last { $0.start <= player.time }?.start
        VStack(spacing: 0) {
            TextField("Find in transcript", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            ScrollViewReader { proxy in
                List(shown) { line in
                    Button { player.seek(to: line.start) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Transcript.clock(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            Text(line.text).foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(line.start == current ? Color.orange.opacity(0.15) : Color.clear)
                    .id(line.start)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: current) { _, new in
                    if let new, query.isEmpty, player.isPlaying { withAnimation { proxy.scrollTo(new, anchor: .center) } }
                }
            }
            if lines.isEmpty {
                Text("No transcript").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            let id = item.id
            lines = await Task.detached { Transcript.paragraphs(ItemFiles(id: id).transcript, every: 8) }.value
        }
    }
}

/// Owns the AVPlayer for the selected item: resume, save position, mark watched at the end.
@MainActor @Observable
final class PlayerController {
    let player = AVPlayer()
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    @ObservationIgnored private var item: Item?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    @ObservationIgnored private var lastSaved: Double = 0

    func load(_ item: Item, file: URL, context: ModelContext) {
        guard self.item?.id != item.id else { return }
        unload()
        self.item = item
        self.context = context
        let playerItem = AVPlayerItem(url: file)
        player.replaceCurrentItem(with: playerItem)
        // Resume, unless it was nearly finished.
        if item.position > 5, item.durationSeconds == 0 || item.position < item.durationSeconds - 10 {
            player.seek(to: CMTime(seconds: item.position, preferredTimescale: 600))
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        rateObserver = player.observe(\.rate) { [weak self] p, _ in
            let playing = p.rate != 0
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
        if player.rate == 0 { player.play() }
    }

    func unload() {
        if let item, time > 0, !item.state.isFinished { item.position = time }
        try? context?.save()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        rateObserver = nil
        timeObserver = nil
        endObserver = nil
        item = nil
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        time = seconds
        guard let item, abs(seconds - lastSaved) >= 5 else { return }
        lastSaved = seconds
        item.position = seconds
        if item.state == .queued, seconds > 0 { item.state = .inProgress }
    }

    private func finished() {
        guard let item, let context else { return }
        item.position = 0
        Library.finish(item, context: context)
    }
}

/// AppKit's player view: native controls, speed menu, Picture in Picture, full screen.
/// (SwiftUI's VideoPlayer crashes on selection in macOS 27.0.)
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.speeds = [0.75, 1, 1.25, 1.5, 1.75, 2].map { AVPlaybackSpeed(rate: $0, localizedName: "\($0)×") }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct AddLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Downloader.self) private var downloader
    @Environment(AppState.self) private var app
    @State private var text = ""
    @State private var from = ""

    var body: some View {
        let link = SharedLink.parse(text)
        VStack(alignment: .leading, spacing: 14) {
            Text("Save for later").font(.headline)
            TextField("Link, or a whole message with a link in it", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            TextField("From (optional, e.g. “Anna · WhatsApp”)", text: $from)
                .textFieldStyle(.roundedBorder)
            Text(link.map { "\($0.kind.label) · \(SourceClassifier.normalizedHost($0.url))" + ($0.note.isEmpty ? "" : " · note: “\($0.note)”") } ?? " ")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Downloads as \(downloader.quality.label)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    app.report(Library.add(text: text, sharedBy: from, context: context, downloader: downloader))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(link == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), SharedLink.parse(clip) != nil { text = clip }
        }
    }
}
