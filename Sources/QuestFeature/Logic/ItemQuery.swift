import Foundation

struct ItemFilter: Sendable, Equatable {
    var text: String = ""
    var types: Set<WorkItemType> = []
    var statusIDs: Set<String> = []
    var labels: Set<String> = []
    var priorityAtLeast: Priority = .none
    var includeDone: Bool = true

    init() {}
}

enum ItemSort: Sendable, Equatable {
    case manual, priority, dueDate, updated, title
}

/// Pure filtering and sorting. Every surface funnels through this so "what is
/// visible" has one definition.
enum ItemQuery {
    static func apply(
        _ filter: ItemFilter, sort: ItemSort,
        to items: [WorkItem],
        scheme: StatusScheme
    ) -> [WorkItem] {
        let query = filter.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = items.filter { item in
            guard !item.isDeleted else { return false }
            if !query.isEmpty {
                let haystack = (item.title + " " + item.body + " " + item.labels.joined(separator: " "))
                    .lowercased()
                guard haystack.contains(query) else { return false }
            }
            if !filter.types.isEmpty, !filter.types.contains(item.type) { return false }
            if !filter.statusIDs.isEmpty, !filter.statusIDs.contains(item.statusID) { return false }
            if !filter.labels.isEmpty, filter.labels.isDisjoint(with: Set(item.labels)) { return false }
            if item.priority < filter.priorityAtLeast { return false }
            if !filter.includeDone, scheme.isDone(item.statusID) { return false }
            return true
        }
        return sorted(matched, by: sort)
    }

    private static func sorted(_ items: [WorkItem], by sort: ItemSort) -> [WorkItem] {
        switch sort {
        case .manual: items.sorted { $0.orderIndex < $1.orderIndex }
        case .priority: items.sorted { $0.priority > $1.priority }
        case .title: items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .updated: items.sorted { $0.updatedAt > $1.updatedAt }
        case .dueDate:
            // Undated items sort last rather than to 1970 — an item with no due
            // date is unscheduled, not overdue.
            items.sorted { a, b in
                switch (a.dueDate, b.dueDate) {
                case (let x?, let y?): x < y
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.orderIndex < b.orderIndex
                }
            }
        }
    }
}
