import Foundation

/// Filter a list by how long things take: watching time for videos, reading time for articles.
public enum LengthFilter: String, CaseIterable, Identifiable, Sendable {
    case any, under5, from5to15, over15
    public var id: Self { self }

    public var label: String {
        switch self {
        case .any: "Any Length"
        case .under5: "Under 5 min"
        case .from5to15: "5–15 min"
        case .over15: "Over 15 min"
        }
    }

    /// Items with no known length (0) only appear under Any Length.
    public func matches(seconds: Double) -> Bool {
        switch self {
        case .any: true
        case .under5: seconds > 0 && seconds < 5 * 60
        case .from5to15: seconds >= 5 * 60 && seconds <= 15 * 60
        case .over15: seconds > 15 * 60
        }
    }
}

public enum ListSort: String, CaseIterable, Identifiable, Sendable {
    case manual, shortest, longest, newest, oldest
    public var id: Self { self }

    public var label: String {
        switch self {
        case .manual: "My Order"
        case .shortest: "Shortest First"
        case .longest: "Longest First"
        case .newest: "Newest Added"
        case .oldest: "Oldest Added"
        }
    }

    /// Whether `a` comes before `b`. Unknown lengths go last in both length orders.
    public func areInIncreasingOrder(seconds a: Double, _ b: Double, added aAdded: Date, _ bAdded: Date, manual aIndex: Double, _ bIndex: Double) -> Bool {
        switch self {
        case .manual: return aIndex < bIndex
        case .newest: return aAdded > bAdded
        case .oldest: return aAdded < bAdded
        case .shortest, .longest:
            if (a > 0) != (b > 0) { return a > 0 }
            if a == b { return aIndex < bIndex }
            return self == .shortest ? a < b : a > b
        }
    }
}
