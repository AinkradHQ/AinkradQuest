import Foundation

/// Validates a proposed status scheme and describes exactly what applying it
/// would do. Pure: no store, no SwiftUI.
///
/// This exists as its own step because scheme editing is the first operation in
/// Quest that rewrites many existing items at once. Separating "work out the
/// consequences" from "carry them out" means the dangerous half is fully
/// testable without a store, and the plan a user confirms is the same value the
/// store executes — the preview cannot drift from the action.
public enum SchemePlan {
    public struct Plan: Sendable, Equatable {
        /// The scheme this plan was diffed against. `applyScheme` refuses to
        /// apply a plan whose `current` no longer matches the stored scheme:
        /// a plan is a snapshot, and the store can be driven over MCP while a
        /// user sits on the confirm step. Without this, the later write silently
        /// reverts the earlier one whenever no item is left dangling.
        public let current: StatusScheme
        public let proposed: StatusScheme
        public let added: [Status]
        public let renamed: [Status]
        public let recoloured: [Status]
        public let recategorised: [Status]
        public let removed: [Status]
        /// removed status id → destination status id
        public let reassignments: [String: String]
        /// Items whose `closedAt` will be stamped, because their status moved into `.done`.
        public let closing: [UUID]
        /// Items whose `closedAt` will be cleared, because their status moved out of `.done`.
        public let reopening: [UUID]
        public let reordered: Bool
        /// How many items change status because their status is being removed.
        public let itemsReassigned: Int
        /// Human- and agent-readable description of the whole plan.
        public let summary: String

        public var changesNothing: Bool {
            added.isEmpty && renamed.isEmpty && recoloured.isEmpty
                && recategorised.isEmpty && removed.isEmpty && !reordered
        }
    }

    public enum Outcome: Equatable {
        case valid(Plan)
        case invalid(String)

        public var value: Plan? { if case .valid(let plan) = self { plan } else { nil } }
        public var message: String? { if case .invalid(let m) = self { m } else { nil } }
    }

    public static func plan(
        current: StatusScheme, proposed: StatusScheme,
        reassignments: [String: String],
        items: [WorkItem]
    ) -> Outcome {
        guard !proposed.statuses.isEmpty else {
            return .invalid("A project needs at least one status.")
        }
        let ids = proposed.statuses.map(\.id)
        guard Set(ids).count == ids.count else {
            return .invalid("Two statuses cannot share an id.")
        }
        guard proposed.statuses.contains(where: { $0.category == .done }) else {
            return .invalid(
                "A scheme needs at least one status in the done category, "
                    + "or nothing could ever be finished.")
        }

        let currentByID = Dictionary(uniqueKeysWithValues: current.statuses.map { ($0.id, $0) })
        let proposedByID = Dictionary(uniqueKeysWithValues: proposed.statuses.map { ($0.id, $0) })

        var added: [Status] = []
        var renamed: [Status] = []
        var recoloured: [Status] = []
        var recategorised: [Status] = []
        for status in proposed.statuses {
            guard let existing = currentByID[status.id] else {
                added.append(status)
                continue
            }
            if existing.name != status.name { renamed.append(status) }
            if existing.colorToken != status.colorToken { recoloured.append(status) }
            if existing.category != status.category { recategorised.append(status) }
        }

        let removed = current.statuses.filter { proposedByID[$0.id] == nil }

        // EVERY entry in the map is validated, not just the ones the loop below
        // happens to reach.
        //
        // A reassignment is a consequence of a removal and nothing else. Left
        // unchecked, an entry keyed on a SURVIVING status is a bulk item
        // rewrite that no change kind describes: the plan reports "no changes"
        // while `applyScheme` moves every item off that status — and if the
        // destination is not in the scheme either, it writes a dangling
        // statusID to disk, the one thing every other write path refuses.
        // Sorted so the message names the same key on every run.
        let removedIDs = Set(removed.map(\.id))
        for (key, destination) in reassignments.sorted(by: { $0.key < $1.key }) {
            guard removedIDs.contains(key) else {
                return .invalid(
                    "'\(key)' is not being removed, so its items cannot be "
                        + "reassigned. Reassignments only say where a REMOVED "
                        + "status's items go; to move items between statuses that "
                        + "both remain, change the items themselves.")
            }
            guard proposedByID[destination] != nil else {
                return .invalid(
                    "Cannot move '\(key)'s items to '\(destination)' — "
                        + "that status is not in the new scheme.")
            }
        }

        // Soft-deleted items carry a statusID too. Reassigning them as well is
        // what stops a restore from resurrecting an item pointing at a status
        // that no longer exists.
        var itemsReassigned = 0
        for status in removed {
            let holders = items.filter { $0.statusID == status.id }
            guard !holders.isEmpty else { continue }
            // The destination itself is already known to exist in `proposed`:
            // the loop above validates every entry in the map, occupied or not.
            guard reassignments[status.id] != nil else {
                return .invalid(
                    "\(status.name) still holds \(holders.count) item(s). "
                        + "Choose where they should go before removing it.")
            }
            itemsReassigned += holders.count
        }

        // A category change is retroactive: it decides whether existing items in
        // that status count as finished.
        var closing: [UUID] = []
        var reopening: [UUID] = []
        for status in recategorised {
            let was = currentByID[status.id]?.category
            let holders = items.filter { $0.statusID == status.id }
            if status.category == .done, was != .done {
                closing += holders.map(\.id)
            } else if was == .done, status.category != .done {
                reopening += holders.map(\.id)
            }
        }

        let survivingOrder = proposed.statuses.map(\.id).filter { currentByID[$0] != nil }
        let previousOrder = current.statuses.map(\.id).filter { proposedByID[$0] != nil }
        let reordered = survivingOrder != previousOrder

        return .valid(
            Plan(
                current: current, proposed: proposed, added: added, renamed: renamed, recoloured: recoloured,
                recategorised: recategorised, removed: removed, reassignments: reassignments,
                closing: closing, reopening: reopening, reordered: reordered,
                itemsReassigned: itemsReassigned,
                summary: describe(
                    added: added, renamed: renamed, recoloured: recoloured,
                    recategorised: recategorised,
                    removed: removed, reassignments: reassignments,
                    proposedByID: proposedByID, currentByID: currentByID,
                    items: items, closing: closing, reopening: reopening,
                    reordered: reordered)))
    }

    private static func describe(
        added: [Status], renamed: [Status], recoloured: [Status],
        recategorised: [Status], removed: [Status],
        reassignments: [String: String],
        proposedByID: [String: Status],
        currentByID: [String: Status],
        items: [WorkItem], closing: [UUID], reopening: [UUID],
        reordered: Bool
    ) -> String {
        var parts: [String] = []
        if !added.isEmpty { parts.append("added \(added.map(\.name).joined(separator: ", "))") }
        if !renamed.isEmpty {
            parts.append(
                "renamed "
                    + renamed.map { status in
                        "\(currentByID[status.id]?.name ?? status.id) to \(status.name)"
                    }.joined(separator: ", "))
        }
        if !recoloured.isEmpty {
            parts.append("recoloured " + recoloured.map(\.name).joined(separator: ", "))
        }
        for status in removed {
            let count = items.filter { $0.statusID == status.id }.count
            if count > 0, let destination = reassignments[status.id] {
                parts.append(
                    "removed \(status.name), moved \(count) item(s) to "
                        + "\(proposedByID[destination]?.name ?? destination)")
            } else {
                parts.append("removed \(status.name)")
            }
        }
        if !closing.isEmpty { parts.append("closed \(closing.count) item(s)") }
        if !reopening.isEmpty { parts.append("reopened \(reopening.count) item(s)") }
        if reordered { parts.append("reordered the columns") }
        return parts.isEmpty ? "no changes" : parts.joined(separator: "; ")
    }
}
