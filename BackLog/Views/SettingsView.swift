import BackLogCore
import ServiceManagement
import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Storage", systemImage: "internaldrive") { StorageSettings() }
            Tab("History Export", systemImage: "square.and.arrow.up") { ExportSettings() }
        }
        .frame(width: 580, height: 600)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                LabeledContent("Save from anywhere") {
                    Text("⌥⌘L").font(.body.monospaced())
                }
                Text("Saves the page open in Safari, Chrome, Arc or Brave — or the link on the clipboard. Also available from the Share menu and the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            Section("Video downloader") {
                ToolsStatus()
            }
            Section("Summaries") {
                if let reason = Summarizer.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    Label("Generated on this Mac with Apple's on-device model.", systemImage: "checkmark.seal")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StorageSettings: View {
    @Bindable private var prefs = Preferences.shared
    @Query private var items: [Item]
    @State private var usage: [String: Int64] = [:]

    var body: some View {
        Form {
            Section("Disk usage") {
                UsageBar(usage: usage, limit: prefs.policy.limitBytes)
            }
            Section("Downloads") {
                Picker("Size", selection: $prefs.policy.quality) {
                    ForEach(DownloadQuality.allCases, id: \.self) { q in
                        Text("\(q.label) · ≈\(Int(q.megabytesPerMinute)) MB/min").tag(q)
                    }
                }
                Picker("Download", selection: $prefs.policy.autoDownload) {
                    Text("The next videos in Up Next").tag(StoragePolicy.AutoDownload.upNext)
                    Text("Everything I add").tag(StoragePolicy.AutoDownload.everything)
                    Text("Only when I press Download").tag(StoragePolicy.AutoDownload.manual)
                }
                if prefs.policy.autoDownload == .upNext {
                    Stepper("Keep the next \(prefs.policy.downloadAhead) offline", value: $prefs.policy.downloadAhead, in: 1...30)
                }
            }
            Section {
                Picker("Watched videos", selection: $prefs.policy.deleteWatchedAfterDays) {
                    Text("Delete right after watching").tag(Int?.some(0))
                    Text("Delete after 1 day").tag(Int?.some(1))
                    Text("Delete after 3 days").tag(Int?.some(3))
                    Text("Delete after a week").tag(Int?.some(7))
                    Text("Keep").tag(Int?.none)
                }
                Picker("Unwatched, never opened", selection: $prefs.policy.deleteUntouchedAfterDays) {
                    Text("Free the file after 14 days").tag(Int?.some(14))
                    Text("Free the file after 30 days").tag(Int?.some(30))
                    Text("Free the file after 90 days").tag(Int?.some(90))
                    Text("Keep").tag(Int?.none)
                }
                Picker("Storage limit", selection: $prefs.policy.limitBytes) {
                    ForEach([5, 10, 25, 50, 100, 200], id: \.self) { gb in Text("\(gb) GB").tag(Int64?.some(Int64(gb) * 1_000_000_000)) }
                    Text("No limit").tag(Int64?.none)
                }
            } header: {
                Text("Auto-delete")
            } footer: {
                Text("Only the video files are deleted. The item, its summary, transcript, article text and picture stay in History forever. Starred items are never auto-deleted. Over the limit, the oldest watched files go first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: items.count) { usage = await Self.measure(items) }
    }

    static func measure(_ items: [Item]) async -> [String: Int64] {
        let snapshot = items.map { ($0.id, $0.state) }
        return await Task.detached(priority: .utility) {
            var usage: [String: Int64] = [:]
            for (id, state) in snapshot {
                let files = ItemFiles(id: id)
                let total = files.sizeOnDisk
                let media = files.media.flatMap { try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize }.map(Int64.init) ?? 0
                let key = state.isFinished ? "Watched, not yet deleted" : (state == .inProgress ? "In progress" : "Unwatched")
                usage[key, default: 0] += media
                usage["Notes, transcripts & pictures", default: 0] += total - media
            }
            return usage
        }.value
    }
}

private struct UsageBar: View {
    let usage: [String: Int64]
    let limit: Int64?
    static let order: [(String, Color)] = [("Unwatched", .orange), ("In progress", .yellow), ("Watched, not yet deleted", .gray), ("Notes, transcripts & pictures", .blue)]

    var body: some View {
        let total = usage.values.reduce(0, +)
        let scale = Double(max(limit ?? total, total, 1))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)).font(.title3.bold())
                if let limit { Text("of \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))").foregroundStyle(.secondary) }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(ItemFiles.root) }
            }
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(Self.order, id: \.0) { name, color in
                        Rectangle().fill(color).frame(width: g.size.width * Double(usage[name] ?? 0) / scale)
                    }
                    Spacer(minLength: 0)
                }
                .background(.quaternary)
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                ForEach(Self.order, id: \.0) { name, color in
                    Label {
                        Text("\(name) \(ByteCountFormatter.string(fromByteCount: usage[name] ?? 0, countStyle: .file))")
                    } icon: {
                        Circle().fill(color).frame(width: 8, height: 8)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

private struct ExportSettings: View {
    @Bindable private var prefs = Preferences.shared
    @Environment(\.modelContext) private var context
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(prefs.exportFolder.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "Not set")
                            .foregroundStyle(prefs.exportFolder == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: choose)
                    }
                }
                Toggle("Keep it up to date automatically", isOn: $prefs.autoExport)
                    .disabled(prefs.exportFolder == nil)
                HStack {
                    Button("Export Now") {
                        let n = StorageManager.exportAll(context: context)
                        message = n == 0 ? "Up to date." : "Wrote \(n) file\(n == 1 ? "" : "s")."
                    }
                    .disabled(prefs.exportFolder == nil)
                    if let folder = prefs.exportFolder { Button("Show in Finder") { NSWorkspace.shared.open(folder) } }
                    Text(message).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Everything you've watched, read, skimmed or skipped, one Markdown file per day (YYYY/YYYY-MM-DD.md) with each item's link, dates, who shared it, your note and its TL;DR — plus backlog.jsonl with the same data as JSON lines. Point it at your LifeLog sources folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        if panel.runModal() == .OK, let url = panel.url { prefs.exportFolder = url }
    }
}

extension StorageManager {
    @MainActor
    static func exportAll(context: ModelContext) -> Int {
        guard let folder = Preferences.shared.exportFolder else { return 0 }
        let items = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        let entries = items.filter(\.state.isFinished).map(exportEntry)
        let n = (try? HistoryExport.write(entries, to: folder)) ?? 0
        Preferences.shared.lastExport = .now
        return n
    }
}

private struct ToolsStatus: View {
    private var tools = ToolManager.shared

    var body: some View {
        LabeledContent("yt-dlp") {
            HStack {
                switch tools.state {
                case .installing(let name): ProgressView().controlSize(.small); Text("Updating \(name)…")
                case .failed(let message): Text(message).foregroundStyle(.red)
                default: Text(tools.ytdlpVersion ?? "—").foregroundStyle(.secondary)
                }
                Button("Update Now") { Task { await tools.ensure(forceUpdate: true) } }
            }
        }
        Text(Tools.ffmpeg == nil ? "Kept up to date automatically. Video and audio are joined by BackLog (no ffmpeg needed)." : "Using ffmpeg from Homebrew to join video and audio.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
