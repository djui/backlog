import AppKit
import BackLogCore
import SwiftData
import SwiftUI

/// Applies a command to one or many items.
@MainActor
enum BatchActions {
    static func perform(_ command: ItemCommand, on items: [Item], context: ModelContext, downloader: Downloader) {
        guard !items.isEmpty else { return }
        switch command {
        case .markDone:
            for item in items where !item.state.isFinished { item.state = .done }
        case .skip:
            for item in items where !item.state.isFinished { item.state = .skipped }
        case .backToUpNext:
            for item in items { item.state = .queued }
        case .toggleStar:
            // Star all unless all are starred already, like Mail's flags.
            let star = !items.allSatisfy(\.starred)
            for item in items { item.starred = star }
        case .download:
            for item in items where item.kind.isPlayable && ItemFiles(id: item.id).media == nil { downloader.enqueue(item, media: true) }
        case .deleteDownload:
            for item in items { downloader.cancel(item); ItemFiles(id: item.id).deleteMedia() }
        case .openOriginal:
            for url in items.prefix(10).compactMap(\.url) { NSWorkspace.shared.open(url) }
        case .copyLink:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(items.compactMap(\.url?.absoluteString).joined(separator: "\n"), forType: .string)
        case .remove:
            for item in items { Library.delete(item, context: context, downloader: downloader) }
        }
        try? context.save()
        Library.onChange?()
    }

    /// Commands that do something for these items.
    static func available(for items: [Item]) -> [ItemCommand] {
        var commands: [ItemCommand] = []
        if items.contains(where: { !$0.state.isFinished }) { commands += [.markDone, .skip] }
        if items.contains(where: \.state.isFinished) { commands.append(.backToUpNext) }
        commands.append(.toggleStar)
        if items.contains(where: { $0.kind.isPlayable && ItemFiles(id: $0.id).media == nil }) { commands.append(.download) }
        if items.contains(where: { ItemFiles(id: $0.id).media != nil }) { commands.append(.deleteDownload) }
        commands += [.openOriginal, .copyLink, .remove]
        return commands
    }
}

/// The right-click menu for one or several items.
struct ItemContextMenu: View {
    let items: [Item]
    let run: (ItemCommand) -> Void

    var body: some View {
        let commands = BatchActions.available(for: items)
        let many = items.count > 1
        ForEach(commands, id: \.self) { command in
            if command == .openOriginal || command == .remove { Divider() }
            Button(label(command, many: many)) { run(command) }
        }
    }

    private func label(_ command: ItemCommand, many: Bool) -> String {
        switch command {
        case .markDone:
            let playable = items.allSatisfy(\.kind.isPlayable), readable = items.allSatisfy { !$0.kind.isPlayable }
            return playable ? "Mark as Watched" : readable ? "Mark as Read" : "Mark as Done"
        case .toggleStar: return items.allSatisfy(\.starred) ? "Unstar" : "Star"
        case .openOriginal: return many ? "Open Originals" : "Open Original"
        case .copyLink: return many ? "Copy Links" : "Copy Link"
        case .remove: return many ? "Remove \(items.count) Items from Library…" : "Remove from Library…"
        default: return command.title
        }
    }
}

/// Shown instead of the detail when several items are selected.
struct BatchPanel: View {
    let items: [Item]
    let run: (ItemCommand) -> Void

    var body: some View {
        let total = items.reduce(0) { $0 + ($1.kind.isPlayable ? $1.durationSeconds : 0) }
        VStack(spacing: 18) {
            ZStack {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { i, item in
                    Thumbnail(item: item)
                        .frame(width: 160, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 4, y: 2)
                        .rotationEffect(.degrees(Double(i - 1) * 6))
                        .offset(x: Double(i - 1) * 14)
                }
            }
            .frame(height: 120)
            VStack(spacing: 4) {
                Text("\(items.count) items selected").font(.title2.bold())
                if total > 0 {
                    Text("\(Int(total / 3600)) h \(Int(total / 60) % 60) min of video").foregroundStyle(.secondary)
                }
            }
            let commands = BatchActions.available(for: items).filter { $0 != .copyLink }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(commands, id: \.self) { command in
                    Button { run(command) } label: {
                        Label(ItemContextMenu.title(command, items: items), systemImage: command.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(command == .remove ? .red : nil)
                }
            }
            .frame(width: 280)
            Text("⌘A selects all · ⌘↩ marks as done · ⌥⌘↩ skips · ⌘⌫ removes")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ItemContextMenu {
    static func title(_ command: ItemCommand, items: [Item]) -> String {
        ItemContextMenu(items: items) { _ in }.label(command, many: items.count > 1)
    }
}

/// The Item menu: every action on the selection, with its shortcut.
struct ItemMenuCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandMenu("Item") {
            Group {
                button(.markDone, "Mark as Watched/Read", .return, .command)
                button(.skip, "Skip", .return, [.command, .option])
                button(.backToUpNext, "Back to Up Next", "u", .command)
                Divider()
                button(.toggleStar, "Star / Unstar", "s", [.command, .option])
                button(.download, "Download", "d", [.command, .option])
                button(.deleteDownload, "Delete Download, Keep in Library", .delete, [.command, .option])
                Divider()
                button(.openOriginal, "Open Original", "o", .command)
                button(.copyLink, "Copy Link", "c", [.command, .shift])
                Divider()
                button(.remove, "Remove from Library…", .delete, .command)
            }
            .disabled(app.selected.isEmpty)
        }
        CommandGroup(before: .sidebar) {
            Button("Up Next") { app.requestedSection = 0 }.keyboardShortcut("1", modifiers: .command)
            Button("Skim") { app.requestedSection = 1 }.keyboardShortcut("2", modifiers: .command)
            Button("Downloading") { app.requestedSection = 2 }.keyboardShortcut("3", modifiers: .command)
            Button("History") { app.requestedSection = 3 }.keyboardShortcut("4", modifiers: .command)
            Divider()
        }
    }

    private func button(_ command: ItemCommand, _ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers) -> some View {
        Button(title) { app.command = command }.keyboardShortcut(key, modifiers: modifiers)
    }
}
