import Foundation

extension ProjectStore {
    /// Applies an already-validated `SchemePlan.Plan` to one project.
    ///
    /// Atomic by construction: every change is made to a local copy of the
    /// document and committed once, so a scheme edit cannot land half-applied.
    /// Validation is NOT repeated here — `SchemePlan.plan` owns it, and the
    /// plan's own contents are what execute, which is what keeps the confirm
    /// step honest.
    func applyScheme(
        _ plan: SchemePlan.Plan, to projectID: UUID,
        actor: ActivityActor
    ) throws {
        guard !isTrashed(projectID), var document = openProject(projectID) else {
            throw QuestError.projectNotFound(projectID)
        }
        // A plan is a snapshot. Refuse it if the scheme moved underneath —
        // otherwise this write silently discards whatever changed it.
        guard document.project.statusScheme == plan.current else {
            throw QuestError.schemeChangedUnderneath
        }
        // A plan that changes nothing must not write. Committing it would append
        // a `schemeUpdated` event summarised "no changes" and bump `updatedAt`,
        // putting an edit in the activity log that never happened.
        guard !plan.changesNothing else { return }

        document.project.statusScheme = plan.proposed
        let stamp = Date()

        // Reassign items off removed statuses. Soft-deleted items included: they
        // keep a statusID, and a restore must not bring back an item pointing at
        // a status that no longer exists.
        //
        // A map entry is honoured ONLY when that status is genuinely absent from
        // the scheme being written. `SchemePlan` refuses entries keyed on a
        // surviving status, and this is the second half of that same rule: a
        // malformed plan reaching here cannot bulk-move items off a status that
        // still exists, nor move any item into one that does not.
        var reassigned: Set<UUID> = []
        if !plan.reassignments.isEmpty {
            for position in document.items.indices {
                let from = document.items[position].statusID
                guard plan.proposed.status(id: from) == nil,
                    let destination = plan.reassignments[from],
                    let target = plan.proposed.status(id: destination)
                else { continue }
                document.items[position].statusID = destination
                // Same rule `setStatus` applies on every status change: closedAt
                // follows the DESTINATION's category. Without this, removing
                // "In Review" into "Done" left items in a done status with no
                // closedAt, and removing "Done" into "Todo" left reopened items
                // still stamped closed. An existing stamp is kept when the
                // destination is also done, so a genuine close time survives.
                document.items[position].closedAt =
                    target.category == .done
                    ? (document.items[position].closedAt ?? stamp)
                    : nil
                document.items[position].updatedAt = stamp
                reassigned.insert(document.items[position].id)
            }
        }

        // A category change decides retroactively whether items in that status
        // count as finished. `closing`/`reopening` were computed from the items
        // that held a RECATEGORISED (therefore surviving) status at plan time,
        // so they never name a reassigned item — skipping them is belt-and-
        // braces against handling one item twice with two different rules.
        let closing = Set(plan.closing)
        let reopening = Set(plan.reopening)
        for position in document.items.indices where !reassigned.contains(document.items[position].id) {
            let id = document.items[position].id
            if closing.contains(id) {
                document.items[position].closedAt = stamp
                document.items[position].updatedAt = stamp
            } else if reopening.contains(id) {
                document.items[position].closedAt = nil
                document.items[position].updatedAt = stamp
            }
        }

        // Last line of defence for the invariant every other write path
        // enforces: no item, live or trashed, may point at a status the scheme
        // does not contain.
        //
        // A plan is a snapshot. Between planning and applying, this same
        // @MainActor store can be driven by the agent over MCP — and the UI's
        // confirm step spans user think-time. So a status that held zero items
        // at plan time (and therefore carries no reassignment entry) can have
        // items by now, and a status the agent added in between is not in
        // `plan.proposed` at all. Both would dangle items on disk.
        //
        // Throwing rather than guessing a destination: `document` is a local
        // copy and `commit` has not run, so nothing is written. The caller
        // surfaces the reason and can re-plan against the current scheme, which
        // is the only way to get a correct answer — inventing a destination
        // would silently move items the user never agreed to move.
        for item in document.items where plan.proposed.status(id: item.statusID) == nil {
            throw QuestError.schemeWouldOrphanItems(item.statusID)
        }

        document.project.updatedAt = stamp
        document.activity.append(
            ActivityEvent(
                projectID: projectID, actor: actor,
                kind: .schemeUpdated,
                summary: plan.summary))
        commit(document)
    }
}
