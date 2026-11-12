import Foundation
import Observation

/// UI state shared across the app: selection, search, the confirmation toast.
@MainActor @Observable
final class AppState {
    var showAddSheet = false
    var searchText = ""
    var focusSearch = false
    var toggleStarSelected = false
    var selection: UUID?
    var toast: String?

    func report(_ result: Library.AddResult) {
        switch result {
        case .added(let item): selection = item.id; toast = "Added to Up Next"
        case .duplicate(let item): selection = item.id; toast = "Already in your library — moved to Up Next"
        case .noLink: toast = "No link found"
        }
        let message = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if self.toast == message { self.toast = nil }
        }
    }
}
