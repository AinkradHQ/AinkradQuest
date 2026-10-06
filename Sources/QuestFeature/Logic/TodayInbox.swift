import Foundation

/// The cross-project landing view's query. Pure, and it takes `now` rather than
/// reading the clock so the sections are testable.
enum TodayInbox {
    struct Result: Sendable {
        let overdue: [WorkItem]
        let dueToday: [WorkItem]
        let active: [WorkItem]
        let recent: [WorkItem]
    }

    static func build(
        items: [WorkItem], scheme: StatusScheme,
        now: Date, calendar: Calendar = .current
    ) -> Result {
        let open = items.filter { !$0.isDeleted && !scheme.isDone($0.statusID) }

        let overdue = open.filter { item in
            guard let due = item.dueDate else { return false }
            return due < now && !calendar.isDate(due, inSameDayAs: now)
        }.sorted { ($0.dueDate ?? now) < ($1.dueDate ?? now) }

        let dueToday = open.filter { item in
            guard let due = item.dueDate else { return false }
            return calendar.isDate(due, inSameDayAs: now)
        }.sorted { $0.priority > $1.priority }

        let active = open.filter { scheme.status(id: $0.statusID)?.category == .active }
            .sorted { $0.priority > $1.priority }

        let recent = Array(open.sorted { $0.updatedAt > $1.updatedAt }.prefix(10))

        return Result(overdue: overdue, dueToday: dueToday, active: active, recent: recent)
    }
}
