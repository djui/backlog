import AVKit
import BackLogCore
import SwiftData
import SwiftUI

struct DetailView: View {
    @Bindable var item: Item
    @Environment(\.modelContext) private var context
    @Environment(Downloader.self) private var downloader

    var body: some View {
        let status = downloader.status(of: item)
        let media = ItemFiles(id: item.id).media
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if let media, !status.isActive {
                        PlayerView(item: item, file: media)
                    } else {
                        Thumbnail(item: item)
                            .overlay {
                                if item.kind.isPlayable {
                                    VStack(spacing: 8) {
                                        StatusLine(item: item, status: status)
                                        if case .failed = status { Button("Try Again") { downloader.enqueue(item) } }
                                        else if !status.isActive { Button("Download") { downloader.enqueue(item) } }
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
                }

                HStack {
                    if item.state.isFinished {
                        Button("Back to Up Next") { item.state = .queued; try? context.save() }
                    } else {
                        Button(item.kind.isPlayable ? "Mark as Watched" : "Mark as Read") { Library.finish(item, context: context) }
                            .buttonStyle(.borderedProminent)
                        Button("Skip") { Library.finish(item, as: .skipped, context: context) }
                    }
                    Spacer()
                    if let url = item.url { Button("Open Original") { NSWorkspace.shared.open(url) } }
                    if media != nil {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([media!]) }
                    }
                }
            }
            .padding(20)
        }
    }

    private var meta: String {
        var parts = [item.kind.label]
        if !item.author.isEmpty { parts.append(item.author) }
        if !item.durationText.isEmpty { parts.append(item.durationText) }
        parts.append("added " + item.addedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

/// Plays a downloaded file, resumes where you left off, and marks the item watched at the end.
struct PlayerView: View {
    let item: Item
    let file: URL
    @Environment(\.modelContext) private var context
    @State private var player = AVPlayer()
    @State private var observer: Any?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        PlayerSurface(player: player)
            .onAppear(perform: start)
            .onDisappear(perform: stop)
    }

    private func start() {
        let playerItem = AVPlayerItem(url: file)
        player.replaceCurrentItem(with: playerItem)
        // Resume, unless it was nearly finished.
        if item.position > 5, item.durationSeconds == 0 || item.position < item.durationSeconds - 10 {
            player.seek(to: CMTime(seconds: item.position, preferredTimescale: 600))
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { time in
            MainActor.assumeIsolated {
                let seconds = time.seconds
                guard seconds.isFinite, seconds > 0 else { return }
                item.position = seconds
                if item.state == .queued { item.state = .inProgress }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { _ in
            MainActor.assumeIsolated {
                item.position = 0
                Library.finish(item, context: context)
            }
        }
    }

    private func stop() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, seconds > 0, !item.state.isFinished { item.position = seconds }
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        try? context.save()
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
