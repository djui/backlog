import BackLogCore
import SafariServices
import SwiftData
import SwiftUI
import WebKit

enum MobileSection { case upNext, history }

struct MobileRootView: View {
    @Environment(AppState.self) private var app
    @State private var showAdd = false

    var body: some View {
        TabView {
            Tab("Up Next", systemImage: "list.bullet") {
                NavigationStack { MobileList(section: .upNext, showAdd: $showAdd) }
            }
            Tab("Skim", systemImage: "text.alignleft") {
                NavigationStack { MobileSkim() }
            }
            Tab("History", systemImage: "clock") {
                NavigationStack { MobileList(section: .history, showAdd: $showAdd) }
            }
            Tab(role: .search) {
                NavigationStack { MobileSearch() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $showAdd) { MobileAddSheet().presentationDetents([.medium]) }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                Label(toast, systemImage: "tray.and.arrow.down.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: app.toast)
    }
}

// MARK: - Lists

struct MobileList: View {
    let section: MobileSection
    @Binding var showAdd: Bool
    @Environment(\.modelContext) private var context
    @Environment(Downloader.self) private var downloader
    @Query(sort: \Item.sortIndex) private var items: [Item]
    @State private var finishedTick = 0
    @State private var showSettings = false
    @AppStorage("lengthFilter") private var length: LengthFilter = .any
    @AppStorage("listSort") private var sort: ListSort = .manual

    private var shown: [Item] { Library.arrange(base, length: length, sort: sort) }

    private var base: [Item] {
        switch section {
        case .upNext: items.filter { !$0.state.isFinished }
        case .history: items.filter(\.state.isFinished).sorted { ($0.consumedAt ?? $0.addedAt) > ($1.consumedAt ?? $1.addedAt) }
        }
    }

    var body: some View {
        let shown = shown
        List {
            ForEach(shown) { item in
                NavigationLink(value: item.id) { MobileRow(item: item) }
                    .swipeActions(edge: .leading) {
                        if !item.state.isFinished {
                            Button { finish(item, .done) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                        } else {
                            Button { item.state = .queued; try? context.save() } label: { Label("Up Next", systemImage: "arrow.uturn.backward") }.tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Library.delete(item, context: context, downloader: downloader) } label: { Label("Delete", systemImage: "trash") }
                        if !item.state.isFinished {
                            Button { finish(item, .skipped) } label: { Label("Skip", systemImage: "forward") }.tint(.gray)
                        }
                    }
                    .contextMenu { menu(for: item) }
            }
            .onMove(perform: section == .upNext && sort == .manual && length == .any ? { Library.move(shown, from: $0, to: $1, context: context) } : nil)
        }
        .listStyle(.plain)
        .navigationTitle(section == .upNext ? "Up Next" : "History")
        .navigationDestination(for: UUID.self) { id in
            if let item = items.first(where: { $0.id == id }) { MobileDetail(item: item) }
        }
        .toolbar {
            if section == .upNext {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add link")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Length", selection: $length) {
                        ForEach(LengthFilter.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Sort", selection: $sort) {
                        ForEach(ListSort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Image(systemName: length == .any && sort == .manual ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter and sort")
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
                ContentUnavailableView(section == .upNext ? "Nothing up next" : "No history yet",
                                       systemImage: section == .upNext ? "tray" : "clock",
                                       description: Text(section == .upNext ? "Share a link to BackLog from any app, or tap +." : "What you watch and read lands here."))
            }
        }
        .refreshable { downloader.resumePending(in: context) }
        .sensoryFeedback(.success, trigger: finishedTick)
        .sheet(isPresented: $showSettings) { MobileSettings() }
    }

    private func finish(_ item: Item, _ state: ItemState) {
        Library.finish(item, as: state, context: context)
        finishedTick += 1
    }

    @ViewBuilder private func menu(for item: Item) -> some View {
        if let url = item.url {
            Button { UIApplication.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
        }
        Button { item.starred.toggle(); try? context.save() } label: {
            Label(item.starred ? "Unstar" : "Star", systemImage: item.starred ? "star.slash" : "star")
        }
    }
}

struct MobileRow: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MobileThumbnail(item: item)
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if !item.durationText.isEmpty {
                        Text(item.durationText)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if item.starred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Text([item.kind.label, item.author.isEmpty ? item.siteName : item.author, item.sharedBy.isEmpty ? "" : "from \(item.sharedBy)"]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let takeaway = item.summary?.takeaway {
                    Text(takeaway).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct MobileThumbnail: View {
    let item: Item

    var body: some View {
        if let image = UIImage(contentsOfFile: ItemFiles(id: item.id).thumbnail.path) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if let url = URL(string: item.thumbnailURL), !item.thumbnailURL.isEmpty {
            AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: item.kind.isPlayable ? "play.rectangle" : "doc.text").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Detail

struct MobileDetail: View {
    @Bindable var item: Item
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @AppStorage("summaryLength") private var length: SummaryLength = .keyPoints
    @State private var showReader = false
    @State private var tick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: primaryAction) {
                    MobileThumbnail(item: item)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            Image(systemName: item.kind.isPlayable ? "play.fill" : "book")
                                .font(.title)
                                .foregroundStyle(.white)
                                .padding(20)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(primaryLabel)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title2.bold())
                    Text(meta).font(.subheadline).foregroundStyle(.secondary)
                    if !item.sharedBy.isEmpty || !item.note.isEmpty {
                        Text([item.sharedBy, item.note].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.callout)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                if let summary = item.summary {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Length", selection: $length) {
                            ForEach(SummaryLength.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(summary.takeaway).font(.body.weight(.semibold))
                        ForEach(summary.points(for: length)) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if let s = point.seconds, let url = timestampURL(s) {
                                    Button(Transcript.clock(s)) { openURL(url) }
                                        .font(.callout.monospacedDigit())
                                        .frame(width: 50, alignment: .leading)
                                }
                                Text(point.text).font(.callout)
                            }
                        }
                        Text(summary.readingTime(for: length)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                    .animation(.snappy, value: length)
                } else if !item.details.isEmpty {
                    Text(item.details).font(.callout).foregroundStyle(.secondary).lineLimit(12)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        // The item's actions take the bottom of the screen; the tab bar would cover them.
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if item.state.isFinished {
                    Button("Back to Up Next") { item.state = .queued; try? context.save() }
                } else {
                    Button(item.kind.isPlayable ? "Watched" : "Read", systemImage: "checkmark") { finish(.done) }
                    Button("Skip", systemImage: "forward") { finish(.skipped) }
                }
                Spacer()
                Button(item.starred ? "Unstar" : "Star", systemImage: item.starred ? "star.fill" : "star") {
                    item.starred.toggle(); try? context.save()
                }
                if let url = item.url { ShareLink(item: url) }
            }
        }
        .sensoryFeedback(.success, trigger: tick)
        .fullScreenCover(isPresented: $showReader) { MobileReader(item: item) }
    }

    private var primaryLabel: String {
        if ItemFiles(id: item.id).hasArticle { return "Read" }
        return item.kind.isPlayable ? "Watch in \(item.siteName.isEmpty ? "the app" : item.siteName)" : "Open"
    }

    private func primaryAction() {
        if ItemFiles(id: item.id).hasArticle { showReader = true; return }
        guard let url = item.url else { return }
        if item.kind.isPlayable { openURL(timestampURL(item.position) ?? url) } else { present(url) }
    }

    /// YouTube links that start at a moment (opens the YouTube app there).
    private func timestampURL(_ seconds: Double) -> URL? {
        guard let url = item.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard SourceClassifier.normalizedHost(url).contains("youtu"), seconds > 1 else { return url }
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "t" } + [URLQueryItem(name: "t", value: "\(Int(seconds))s")]
        return c.url
    }

    private func present(_ url: URL) {
        let safari = SFSafariViewController(url: url)
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first?.present(safari, animated: true)
    }

    private func finish(_ state: ItemState) {
        Library.finish(item, as: state, context: context)
        tick += 1
    }

    private var meta: String {
        var parts = [item.kind.label]
        if !item.author.isEmpty { parts.append(item.author) }
        if !item.durationText.isEmpty { parts.append(item.durationText) }
        parts.append("added " + item.addedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

/// The saved article, offline, in a reading layout that follows light/dark mode.
struct MobileReader: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            ReaderWeb(files: ItemFiles(id: item.id), title: item.title, byline: [item.author, item.siteName].filter { !$0.isEmpty }.joined(separator: " · "))
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Mark as Read", systemImage: "checkmark") {
                            Library.finish(item, context: context)
                            dismiss()
                        }
                    }
                }
        }
    }
}

struct ReaderWeb: UIViewRepresentable {
    let files: ItemFiles
    let title: String
    let byline: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        guard let body = try? String(contentsOf: files.articleHTML, encoding: .utf8) else { return view }
        let page = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark"><style>
        body { font: 19px/1.6 "New York", Georgia, serif; margin: 20px 20px 80px; color: CanvasText; background: Canvas; -webkit-text-size-adjust: 100%; }
        h1 { font-size: 28px; line-height: 1.2; } .byline { font: 14px -apple-system, sans-serif; color: GrayText; margin-bottom: 24px; }
        img, video, figure { max-width: 100%; height: auto; border-radius: 8px; } a { color: #e06a2c; }
        pre { overflow-x: auto; font-size: 14px; } blockquote { margin-left: 0; padding-left: 14px; border-left: 3px solid #ccc; }
        </style></head><body><h1>\(title.replacingOccurrences(of: "<", with: "&lt;"))</h1><div class="byline">\(byline.replacingOccurrences(of: "<", with: "&lt;"))</div>\(body)</body></html>
        """
        let reader = files.directory.appending(path: "reader.html")
        try? page.write(to: reader, atomically: true, encoding: .utf8)
        view.loadFileURL(reader, allowingReadAccessTo: files.directory)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

// MARK: - Skim

struct MobileSkim: View {
    @Query(sort: \Item.sortIndex) private var items: [Item]
    @Environment(\.modelContext) private var context
    @AppStorage("skimLength") private var length: SummaryLength = .tldr
    @State private var tick = 0

    var body: some View {
        let queue = items.filter { !$0.state.isFinished }
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(queue) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        MobileThumbnail(item: item)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        Text(item.title).font(.headline)
                        Text([item.kind.label, item.author, item.durationText].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let s = item.summary {
                            Text(s.takeaway).font(.callout.weight(.medium))
                            ForEach(s.points(for: length)) { Text("• " + $0.text).font(.callout).foregroundStyle(.secondary) }
                        } else if !item.details.isEmpty {
                            Text(item.details).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                        }
                        HStack {
                            NavigationLink(value: item.id) { Text("Open") }.buttonStyle(.glassProminent)
                            Button("Notes only") {
                                ItemFiles(id: item.id).deleteMedia()
                                Library.finish(item, as: .skimmed, context: context); tick += 1
                            }
                            .buttonStyle(.glass)
                            Button("Skip") { Library.finish(item, as: .skipped, context: context); tick += 1 }
                                .buttonStyle(.glass)
                        }
                    }
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
            .padding(.horizontal)
            .animation(.snappy, value: queue.map(\.id))
        }
        .navigationTitle("Skim")
        .navigationDestination(for: UUID.self) { id in
            if let item = items.first(where: { $0.id == id }) { MobileDetail(item: item) }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Length", selection: $length) {
                    ForEach(SummaryLength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
        }
        .overlay { if queue.isEmpty { ContentUnavailableView("Nothing to skim", systemImage: "text.alignleft") } }
        .sensoryFeedback(.impact(weight: .light), trigger: tick)
    }
}

// MARK: - Search

struct MobileSearch: View {
    @Query private var items: [Item]
    @Environment(SearchIndex.self) private var search
    @State private var query = ""
    @State private var hits: [SearchIndex.Hit] = []

    var body: some View {
        List(hits) { hit in
            NavigationLink(value: hit.item.id) {
                VStack(alignment: .leading, spacing: 4) {
                    MobileRow(item: hit.item)
                    if !hit.snippet.isEmpty { Text(hit.snippet).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .navigationDestination(for: UUID.self) { id in
            if let item = items.first(where: { $0.id == id }) { MobileDetail(item: item) }
        }
        .searchable(text: $query, prompt: "Titles, captions, pictures, what it was about…")
        .overlay {
            if query.isEmpty {
                ContentUnavailableView("Find anything you saved", systemImage: "magnifyingglass",
                                       description: Text("Search by words, or by what you remember — “that chickpea recipe reel”."))
            } else if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(150))
            hits = search.search(query, in: items)
        }
    }
}

// MARK: - Add & settings

struct MobileAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Downloader.self) private var downloader
    @Environment(AppState.self) private var app
    @State private var text = ""
    @State private var from = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Link, or a message with a link", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    PasteButton(payloadType: String.self) { strings in text = strings.first ?? "" }
                }
                Section { TextField("From (e.g. Anna)", text: $from) }
                if let link = SharedLink.parse(text) {
                    Section { Label("\(link.kind.label) · \(SourceClassifier.normalizedHost(link.url))", systemImage: "link") }
                }
            }
            .navigationTitle("Save for Later")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.report(Library.add(text: text, sharedBy: from, context: context, downloader: downloader))
                        dismiss()
                    }
                    .disabled(SharedLink.parse(text) == nil)
                }
            }
        }
    }
}

struct MobileSettings: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Keep the next \(prefs.policy.downloadAhead) articles offline", value: $prefs.policy.downloadAhead, in: 1...20)
                } header: { Text("On this iPhone") } footer: {
                    Text("Videos and reels open in their own apps. Your list, notes and summaries sync with your Mac through iCloud; downloads stay on each device.")
                }
                Section("Summaries") {
                    if let reason = Summarizer.unavailableReason { Label(reason, systemImage: "exclamationmark.triangle") }
                    else { Label("Made on your devices with Apple Intelligence.", systemImage: "checkmark.seal") }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Link("Website", destination: URL(string: "https://uwe.social/backlog/")!)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
