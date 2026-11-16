import BackLogCore
import SafariServices
import SwiftData
import SwiftUI
import WebKit

enum MobileSection { case upNext, history }

struct MobileRootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdd = false

    var body: some View {
        TabView {
            Tab("Up Next", systemImage: "list.bullet") {
                ItemSplit { MobileList(section: .upNext, showAdd: $showAdd, selection: $0) }
            }
            Tab("History", systemImage: "clock") {
                ItemSplit { MobileList(section: .history, showAdd: $showAdd, selection: $0) }
            }
            Tab(role: .search) {
                ItemSplit { MobileSearch(selection: $0) }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $showAdd) { MobileAddSheet().presentationDetents([.medium, .large]) }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                Label(toast, systemImage: "tray.and.arrow.down.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: app.toast)
    }
}

// MARK: - Lists

/// A list and the selected item: side by side on iPad, pushed on iPhone.
struct ItemSplit<Content: View>: View {
    @ViewBuilder let list: (Binding<UUID?>) -> Content
    @Query private var items: [Item]
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            list($selection)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
        } detail: {
            if let id = selection, let item = items.first(where: { $0.id == id }) {
                MobileDetail(item: item).id(id)
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "play.rectangle",
                                       description: Text("Pick something from the list."))
            }
        }
    }
}

struct MobileList: View {
    let section: MobileSection
    @Binding var showAdd: Bool
    @Binding var selection: UUID?
    @Environment(\.modelContext) private var context
    @Environment(Downloader.self) private var downloader
    @Query(sort: \Item.sortIndex) private var items: [Item]
    @State private var finishedTick = 0
    @State private var showSettings = false
    @State private var pendingDelete: Item?
    @AppStorage("lengthFilter") private var length: LengthFilter = .any
    @AppStorage("listSort") private var sort: ListSort = .manual
    @AppStorage("tagFilter") private var tagFilter = ""

    private var shown: [Item] {
        let tagged = tagFilter.isEmpty ? base : base.filter { $0.hasTag(tagFilter) }
        return Library.arrange(tagged, length: length, sort: sort)
    }

    private var allTags: [String] {
        var seen = Set<String>()
        return items.flatMap(\.tags).filter { seen.insert($0.lowercased()).inserted }.sorted { $0.lowercased() < $1.lowercased() }
    }

    private var base: [Item] {
        switch section {
        case .upNext: items.filter { !$0.state.isFinished }
        case .history: items.filter(\.state.isFinished).sorted { ($0.consumedAt ?? $0.addedAt) > ($1.consumedAt ?? $1.addedAt) }
        }
    }

    var body: some View {
        let shown = shown
        List(selection: $selection) {
            ForEach(shown) { item in
                NavigationLink(value: item.id) { MobileRow(item: item) }
                    .swipeActions(edge: .leading) {
                        if !item.state.isFinished {
                            Button { finish(item, .done) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                        } else {
                            Button { item.state = .queued; try? context.save() } label: { Label("Up Next", systemImage: "arrow.uturn.backward") }.tint(.orange)
                        }
                    }
                    // No full swipe: deleting also throws away the notes, summary and downloads.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }.tint(.red)
                        if !item.state.isFinished {
                            Button { finish(item, .skipped) } label: { Label("Skip", systemImage: "forward") }.tint(.gray)
                        }
                    }
                    .contextMenu { menu(for: item) }
            }
            .onMove(perform: section == .upNext && sort == .manual && length == .any && tagFilter.isEmpty ? { Library.move(shown, from: $0, to: $1, context: context) } : nil)
        }
        .listStyle(.plain)
        .navigationTitle(section == .upNext ? "Up Next" : "History")
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = pendingDelete {
                    if selection == item.id { selection = nil }
                    Library.delete(item, context: context, downloader: downloader)
                }
                pendingDelete = nil
            }
        } message: {
            Text("Its notes, summary and downloads are deleted too. To keep it in History, mark it as done instead.")
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
                    if !allTags.isEmpty {
                        Picker("Tag", selection: $tagFilter) {
                            Text("All Tags").tag("")
                            ForEach(allTags, id: \.self) { Text("#\($0)").tag($0) }
                        }
                    }
                    Picker("Length", selection: $length) {
                        ForEach(LengthFilter.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Sort", selection: $sort) {
                        ForEach(ListSort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Image(systemName: length == .any && sort == .manual && tagFilter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter and sort")
            }
        }
        .overlay {
            if shown.isEmpty, !tagFilter.isEmpty, !base.isEmpty {
                ContentUnavailableView {
                    Label("Nothing tagged #\(tagFilter)", systemImage: "number")
                } actions: {
                    Button("Show All Tags") { tagFilter = "" }
                }
            } else if shown.isEmpty, length != .any, !base.isEmpty {
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
        Button { Library.refresh(item, context: context, downloader: downloader) } label: {
            Label("Refresh Details", systemImage: "arrow.clockwise")
        }
    }
}

struct MobileRow: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(item: item)
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if !item.durationText.isEmpty {
                        Text(item.durationText)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                            .dynamicTypeSize(...DynamicTypeSize.xLarge)  // A badge on a fixed-size picture; the row's value reads it.
                            .padding(4)
                            .accessibilityHidden(true)  // Read as the row's value instead.
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if item.starred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel("Starred") }
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Text([item.kind.label, item.author.isEmpty ? item.siteName : item.author, item.sharedBy.isEmpty ? "" : "from \(item.sharedBy)"]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let takeaway = item.summary?.takeaway {
                    Text(takeaway).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                let tags = item.tags
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)").font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.tagFill, in: Capsule())
                                .foregroundStyle(Color.tagInk)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        // One stop for VoiceOver: title and details first, then the length.
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.durationText)
    }
}

// MARK: - Detail

struct MobileDetail: View {
    @Bindable var item: Item
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("summaryLength") private var length: SummaryLength = .keyPoints
    @State private var showReader = false
    @State private var showTranscript = false
    /// Timestamp columns grow with the text size, so "1:02:03" never truncates.
    @ScaledMetric(relativeTo: .callout) private var pointClockWidth = 50
    @ScaledMetric(relativeTo: .caption) private var lineClockWidth = 44
    @State private var tick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: primaryAction) {
                    Thumbnail(item: item, maxPixels: 1600)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            Image(systemName: primarySymbol)
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
                    SharedByCard(item: item)
                    ItemTagsEditor(item: item)
                        .padding(12)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
                                        .frame(width: pointClockWidth, alignment: .leading)
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

                let transcript = Transcript.paragraphs(item.transcript, every: 20)
                if !transcript.isEmpty {
                    DisclosureGroup(isExpanded: $showTranscript) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(transcript) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if let url = timestampURL(line.start), url != item.url {
                                        Button(Transcript.clock(line.start)) { openURL(url) }
                                            .font(.caption.monospacedDigit())
                                            .frame(width: lineClockWidth, alignment: .leading)
                                    } else {
                                        Text(Transcript.clock(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(width: lineClockWidth, alignment: .leading)
                                    }
                                    Text(line.text).font(.callout).textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("Transcript", systemImage: "text.quote").font(.headline)
                    }
                    .padding(16)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding()
            .frame(maxWidth: 720)  // A readable measure on iPad.
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        // On iPhone the item's actions take the bottom of the screen, where the tab bar would cover them.
        .toolbarVisibility(sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if item.state.isFinished {
                    Button("Back to Up Next") { item.state = .queued; try? context.save() }
                } else {
                    Button(item.kind.doneLabel, systemImage: "checkmark") { finish(.done) }
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

    private var primarySymbol: String {
        if ItemFiles(id: item.id).hasArticle { return "book" }
        switch item.kind {
        case .video, .reel: return "play.fill"
        case .podcast: return "headphones"
        case .music: return "music.note"
        default: return "safari"
        }
    }

    private var primaryLabel: String {
        if ItemFiles(id: item.id).hasArticle { return "Read" }
        return item.kind.isTimed ? "\(item.kind.openVerb) in \(item.siteName.isEmpty ? "the app" : item.siteName)" : "Open"
    }

    private func primaryAction() {
        if ItemFiles(id: item.id).hasArticle { showReader = true; return }
        guard let url = item.url else { return }
        if item.kind.isPlayable { openURL(timestampURL(item.position) ?? url) }
        else if item.kind.isTimed { openURL(url) }  // Spotify, Apple Podcasts…: their own app, at the shared time.
        else { present(url) }
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
        if item.kind == .podcast, item.position > 0 { parts.append("from \(Transcript.clock(item.position))") }
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
        html { font: -apple-system-body; -webkit-text-size-adjust: 100%; }
        body { font-family: "New York", Georgia, serif; font-size: 1.12em; line-height: 1.6; max-width: 38em; margin: 20px auto 80px; padding: 0 20px; color: CanvasText; background: Canvas; }
        h1 { font-size: 1.5em; line-height: 1.2; } .byline { font-family: -apple-system, sans-serif; font-size: .75em; color: GrayText; margin-bottom: 24px; }
        img, video, figure { max-width: 100%; height: auto; border-radius: 8px; }
        a { color: #a34a00; } @media (prefers-color-scheme: dark) { a { color: #ff9f0a; } }
        pre { overflow-x: auto; font-size: .75em; } blockquote { margin-left: 0; padding-left: 14px; border-left: 3px solid color-mix(in srgb, CanvasText 20%, transparent); }
        </style></head><body><h1>\(title.replacingOccurrences(of: "<", with: "&lt;"))</h1><div class="byline">\(byline.replacingOccurrences(of: "<", with: "&lt;"))</div>\(body)</body></html>
        """
        let reader = files.directory.appending(path: "reader.html")
        try? page.write(to: reader, atomically: true, encoding: .utf8)
        view.loadFileURL(reader, allowingReadAccessTo: files.directory)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

// MARK: - Search

struct MobileSearch: View {
    @Binding var selection: UUID?
    @Query private var items: [Item]
    @Environment(SearchIndex.self) private var search
    @State private var query = ""
    @State private var hits: [SearchIndex.Hit] = []

    var body: some View {
        List(hits, selection: $selection) { hit in
            NavigationLink(value: hit.item.id) {
                VStack(alignment: .leading, spacing: 4) {
                    MobileRow(item: hit.item)
                    if !hit.snippet.isEmpty { Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
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
    @State private var tags: [String] = []
    @State private var finished = false

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
                Section("From") {
                    TextField("Who or where it’s from", text: $from)
                    SuggestionChips(values: Suggestions.rank(Recents.from, presets: Recents.sourcePresets, typed: from, excluding: [from], limit: 10)) { from = $0 }
                }
                Section("Tags") { TagField(tags: $tags) }
                if let link = SharedLink.parse(text) {
                    Section { Label("\(link.kind.label) · \(SourceClassifier.normalizedHost(link.url))", systemImage: "link") }
                }
                Section {
                    Toggle("Already \((SharedLink.parse(text)?.kind.doneLabel ?? "Done").lowercased())", isOn: $finished)
                } footer: {
                    if finished { Text("Goes straight to History.") }
                }
            }
            .navigationTitle("Save for Later")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Recents.remember(from: from)
                        Recents.remember(tags: tags)
                        let withTags = tags.isEmpty ? text : text + "\n" + Tags.compose(note: "", tags: tags)
                        app.report(Library.add(text: withTags, sharedBy: from, finished: finished, context: context, downloader: downloader))
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
                } header: { Text("On this \(UIDevice.current.model)") } footer: {
                    Text("Videos and reels open in their own apps. Your list, notes and summaries sync with your other devices through iCloud; downloads stay on each device.")
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
