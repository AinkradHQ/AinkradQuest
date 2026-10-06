import Foundation

struct TimelineBar: Sendable, Identifiable {
    var id: UUID { itemID }
    let itemID: UUID
    let title: String
    let start: Date
    let end: Date
    /// Row index. Bars that overlap in time never share a lane.
    let lane: Int
    /// True when this span was computed from scheduled descendants rather
    /// than dates the item itself carries.
    let isDerived: Bool

    init(itemID: UUID, title: String, start: Date, end: Date, lane: Int, isDerived: Bool = false) {
        self.itemID = itemID
        self.title = title
        self.start = start
        self.end = end
        self.lane = lane
        self.isDerived = isDerived
    }
}

enum TimelineLayout {
    struct Result: Sendable {
        let bars: [TimelineBar]
        /// Items with neither a start nor a due date. They get their own rail
        /// rather than being dropped — a task invisible because nobody dated it
        /// is a task that gets forgotten.
        let unscheduled: [WorkItem]
    }

    static func build(items: [WorkItem]) -> Result {
        let live = items.filter { !$0.isDeleted }
        var unscheduled: [WorkItem] = []
        var dated: [(item: WorkItem, start: Date, end: Date, isDerived: Bool)] = []

        for item in live {
            switch (item.startDate, item.dueDate) {
            case (let start?, let due?): dated.append((item, min(start, due), max(start, due), false))
            case (let start?, nil): dated.append((item, start, start, false))
            case (nil, let due?): dated.append((item, due, due, false))
            case (nil, nil): unscheduled.append(item)
            }
        }

        // An epic with no dates of its own but scheduled children spans them.
        // The spec promised this shape; without it a perfectly well-planned
        // epic drops to the unscheduled rail purely because nobody typed dates
        // on the container.
        for epic in live
        where epic.type == .epic
            && epic.startDate == nil && epic.dueDate == nil
        {
            let scheduled = HierarchyRules.descendants(of: epic.id, in: live)
                .filter { !$0.isDeleted }
                .compactMap { child -> (start: Date, end: Date)? in
                    switch (child.startDate, child.dueDate) {
                    case (let start?, let due?): return (min(start, due), max(start, due))
                    case (let start?, nil): return (start, start)
                    case (nil, let due?): return (due, due)
                    case (nil, nil): return nil
                    }
                }
            guard let earliest = scheduled.map(\.start).min(),
                let latest = scheduled.map(\.end).max()
            else { continue }
            dated.append((epic, earliest, latest, true))
            unscheduled.removeAll { $0.id == epic.id }
        }

        // Greedy lane packing over start-sorted bars: place each bar in the
        // first lane whose last bar ended before this one starts.
        dated.sort { $0.start < $1.start }
        var laneEnds: [Date] = []
        var bars: [TimelineBar] = []
        for entry in dated {
            let lane = laneEnds.firstIndex { $0 < entry.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(entry.end) } else { laneEnds[lane] = entry.end }
            bars.append(
                TimelineBar(
                    itemID: entry.item.id, title: entry.item.title,
                    start: entry.start, end: entry.end, lane: lane,
                    isDerived: entry.isDerived))
        }
        return Result(bars: bars, unscheduled: unscheduled)
    }
}
