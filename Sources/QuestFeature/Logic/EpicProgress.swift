import Foundation

enum EpicProgress {
    struct Progress: Sendable, Equatable {
        let done: Int
        let total: Int
    }

    /// Counts every live descendant, not just direct children: a subtask is
    /// real work, and an epic whose progress ignored them would lie.
    static func rollup(
        epicID: UUID, in items: [WorkItem],
        scheme: StatusScheme
    ) -> Progress {
        let descendants = HierarchyRules.descendants(of: epicID, in: items)
            .filter { !$0.isDeleted }
        let done = descendants.filter { scheme.isDone($0.statusID) }.count
        return Progress(done: done, total: descendants.count)
    }
}
