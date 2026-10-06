import Foundation

/// What a surface reads: mirror plus overlay plus link, joined once.
///
/// The point of this type is that NO surface learns whether a project is
/// linked. `isLinked` exists for presentation — showing which fields sync —
/// never for branching on provider behaviour.
public struct WorkItemView: Sendable, Identifiable {
    public let item: WorkItem
    public let overlay: ItemOverlay
    public let remoteRef: RemoteRef?

    public var id: UUID { item.id }

    public var title: String { item.title }
    public var statusID: String { item.statusID }
    public var dueDate: Date? { item.dueDate }

    public var personalOrder: Int? { overlay.personalOrder }
    public var notes: String { overlay.notes }
    /// Manually logged minutes only. Session time is DERIVED elsewhere and
    /// deliberately not summed in here, so the two never disagree.
    public var loggedMinutes: Int { overlay.timeEntries.reduce(0) { $0 + $1.minutes } }
    public var isLinked: Bool { remoteRef != nil }

    public init(item: WorkItem, overlay: ItemOverlay, remoteRef: RemoteRef?) {
        self.item = item
        self.overlay = overlay
        self.remoteRef = remoteRef
    }
}

public enum WorkItemViewBuilder {
    /// Driven by ITEMS, never by overlay rows: an overlay row whose item was
    /// purged must not resurrect as a phantom with notes and no title. Order is
    /// preserved exactly — the surfaces already sort, and a join that quietly
    /// reorders would break them.
    public static func build(
        items: [WorkItem], overlay: ProjectOverlay,
        linkMap: LinkMap
    ) -> [WorkItemView] {
        items.map { item in
            WorkItemView(
                item: item,
                overlay: overlay.item(item.id) ?? ItemOverlay(),
                remoteRef: linkMap.remoteRef(for: item.id))
        }
    }
}
