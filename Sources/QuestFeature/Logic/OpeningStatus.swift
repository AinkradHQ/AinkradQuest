import Foundation

extension StatusScheme {
    /// The status a newly created item opens in, derived from THIS scheme —
    /// never a hardcoded `"todo"`, which a general-kind scheme need not contain
    /// and which `StatusSchemeEditor` lets the user remove or rename outright.
    /// The store rejects an unknown status, so hardcoding it turns capture into
    /// a danger toast on every submit.
    ///
    /// The first not-done status, because a new item that starts life done is
    /// nonsense; falling back to the first status only if every status is a
    /// done status. `nil` when the scheme is empty, which the callers treat as
    /// "withhold the action" rather than "guess".
    var openingStatusID: String? {
        statuses.first { !isDone($0.id) }?.id ?? statuses.first?.id
    }
}
