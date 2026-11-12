import Foundation

/// An error with a message meant for people: a tool's stderr, a page's status.
struct ToolFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
