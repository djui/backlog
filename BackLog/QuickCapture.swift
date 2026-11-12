import AppKit
import BackLogCore
import Carbon.HIToolbox
import SwiftUI

/// ⌥⌘L from any app: saves the page in the frontmost browser, or else the link on the clipboard,
/// and confirms with a small heads-up display.
@MainActor
final class QuickCapture {
    static let shared = QuickCapture()
    var onCapture: ((String) -> Library.AddResult)?
    private var hotKey: EventHotKeyRef?
    private var hud: NSPanel?

    func registerHotKey() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in QuickCapture.shared.capture() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x424C4F47), id: 1)  // "BLOG"
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func capture() {
        let text = Self.frontBrowserURL() ?? NSPasteboard.general.string(forType: .string) ?? ""
        guard let result = onCapture?(text) else { return }
        switch result {
        case .added(let item): showHUD("Saved to BackLog", item.title)
        case .duplicate(let item): showHUD("Already saved — moved to Up Next", item.title)
        case .noLink: showHUD("No link to save", "Open a page in your browser or copy a link")
        }
    }

    /// The current tab's URL in the frontmost browser, via Apple Events (asks permission once).
    static func frontBrowserURL() -> String? {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        let script: String
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            script = "tell application id \"\(bundleID)\" to get URL of front document"
        case "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi":
            script = "tell application id \"\(bundleID)\" to get URL of active tab of front window"
        default:
            return nil
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }

    private func showHUD(_ title: String, _ subtitle: String) {
        hud?.close()
        let view = NSHostingView(rootView: HUDView(title: title, subtitle: subtitle))
        view.frame.size = view.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - view.fittingSize.width / 2, y: f.minY + 120))
        }
        panel.orderFrontRegardless()
        hud = panel
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                Task { @MainActor in panel.close() }
            }
        }
    }
}

private struct HUDView: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .capsule)
        .padding(10)
    }
}

/// The menu bar item: save the clipboard link, see downloads, open the window.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(Downloader.self) private var downloader
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app

    var body: some View {
        Button("Save Link from Clipboard") {
            app.report(Library.add(text: NSPasteboard.general.string(forType: .string) ?? "", context: context, downloader: downloader))
        }
        Button("Save Current Browser Page  ⌥⌘L") { QuickCapture.shared.capture() }
        Divider()
        let active = downloader.activeCount
        Text(active == 0 ? "No downloads" : "Downloading \(active)…")
        Divider()
        Button("Open BackLog") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit BackLog") { NSApp.terminate(nil) }
    }
}
