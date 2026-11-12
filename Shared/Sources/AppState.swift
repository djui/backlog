import Foundation
import Observation

/// UI state shared across the app: selection, search, the confirmation toast.
@MainActor @Observable
final class AppState {
    var showAddSheet = false
    var searchText = ""
    var focusSearch = false
    /// The selected items; several with ⌘A, ⇧-click or ⌘-click.
    var selected: Set<UUID> = []
    /// The one selected item, when exactly one is selected.
    var selection: UUID? {
        get { selected.count == 1 ? selected.first : nil }
        set { selected = newValue.map { [$0] } ?? [] }
    }
    /// A menu command or shortcut to apply to the selection; the window performs it.
    var command: ItemCommand?
    /// A section switch from the menu (⌘1–⌘4), by position.
    var requestedSection: Int?
    var toast: String?

    func report(_ result: Library.AddResult) {
        switch result {
        case .added(let item): selection = item.id; toast = "Added to Up Next"
        case .duplicate(let item): selection = item.id; toast = "Already in your library — moved to Up Next"
        case .imported(let added, let skipped):
            toast = "Imported \(added) link\(added == 1 ? "" : "s")" + (skipped > 0 ? " · \(skipped) already saved" : "")
        case .noLink: toast = "No link found"
        }
        let message = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if self.toast == message { self.toast = nil }
        }
    }
}

/// What can be done to the selected items, from the Item menu, shortcuts or the batch panel.
enum ItemCommand: Equatable {
    case markDone, skip, backToUpNext, toggleStar, download, deleteDownload, refresh, openOriginal, copyLink, remove

    var title: String {
        switch self {
        case .markDone: "Mark as Watched/Read"
        case .skip: "Skip"
        case .backToUpNext: "Back to Up Next"
        case .toggleStar: "Star"
        case .download: "Download"
        case .deleteDownload: "Delete Download, Keep in Library"
        case .refresh: "Refresh Details"
        case .openOriginal: "Open Original"
        case .copyLink: "Copy Link"
        case .remove: "Remove from Library…"
        }
    }

    var symbol: String {
        switch self {
        case .markDone: "checkmark.circle"
        case .skip: "forward"
        case .backToUpNext: "arrow.uturn.backward"
        case .toggleStar: "star"
        case .download: "arrow.down.circle"
        case .deleteDownload: "externaldrive.badge.minus"
        case .refresh: "arrow.clockwise"
        case .openOriginal: "safari"
        case .copyLink: "link"
        case .remove: "trash"
        }
    }
}
