import Foundation

/// Pure decision logic for `StatusSchemeEditor`, extracted so the "read the
/// scheme fresh, not a stale capture" behavior is a parameter a test controls
/// directly, independent of SwiftUI/View lifecycle.
enum SchemeEditorState {
    /// Plans a proposed set of drafts against an explicitly-passed `current`
    /// scheme. Forwards straight to `SchemePlan.plan`; the only reason this
    /// exists is to make `current` a parameter instead of something read off
    /// `self.project` inside a View.
    static func plan(
        current: StatusScheme, drafts: [StatusDraft],
        reassignments: [String: String], items: [WorkItem]
    ) -> SchemePlan.Outcome {
        SchemePlan.plan(
            current: current, proposed: StatusDraft.scheme(from: drafts),
            reassignments: prune(reassignments, current: current, drafts: drafts),
            items: items)
    }

    /// Drops reassignment entries that no longer describe a removal.
    ///
    /// The editor accumulates `reassignments` as rows come and go, and an entry
    /// can outlive the removal that created it: remove "In Review", pick a
    /// destination, then add a row named "In Review" again — `StatusDraft.make`
    /// re-mints the same id `in_review`, so the row stops being a removal and
    /// its picker disappears from the sheet, while the stale entry survives
    /// invisibly and would still move every one of that status's items.
    /// Pruning here rather than in the view means the view cannot forget.
    static func prune(
        _ reassignments: [String: String], current: StatusScheme,
        drafts: [StatusDraft]
    ) -> [String: String] {
        let surviving = Set(drafts.map(\.id))
        let removed = Set(current.statuses.map(\.id)).subtracting(surviving)
        return reassignments.filter { removed.contains($0.key) }
    }

    /// Given a just-applied plan, the next drafts (re-seeded from
    /// `plan.proposed`) and cleared reassignments.
    static func afterApply(_ plan: SchemePlan.Plan) -> (
        drafts: [StatusDraft],
        reassignments: [String: String]
    ) {
        (StatusDraft.drafts(from: plan.proposed), [:])
    }

    /// The editor state to adopt when an apply was refused as stale: rows
    /// re-seeded from the scheme as it now stands, and reassignments dropped
    /// because they referred to removals computed against the old scheme.
    static func afterStaleRefusal(currentScheme: StatusScheme)
        -> (drafts: [StatusDraft], reassignments: [String: String])
    {
        (StatusDraft.drafts(from: currentScheme), [:])
    }
}
