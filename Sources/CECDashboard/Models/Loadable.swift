import Foundation

/// Async-data state for a view. Distinguishes the failure modes the reliability
/// review called out so the UI never renders "empty" and "broken" identically:
/// `loaded([])` is an honest empty state, `failed` is an error, `stale` keeps the
/// last good value visible while a refresh failed.
enum Loadable<T> {
    case idle
    case loading
    case loaded(T)
    case stale(T, since: Date, message: String)
    case failed(message: String)

    /// The last successfully-loaded value, if any (loaded or stale).
    /// The stale banner text — non-nil only in `.stale`.
    var staleMessage: String? {
        if case .stale(_, _, let message) = self { return message }
        return nil
    }

    var value: T? {
        switch self {
        case .loaded(let v), .stale(let v, _, _): return v
        default: return nil
        }
    }
}
