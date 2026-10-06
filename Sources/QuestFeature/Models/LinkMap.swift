import Foundation

/// A provider's own name for an item, scoped by the connection it came from.
/// Two Jira sites can both hold a `QST-1`; they are not the same work.
public struct RemoteRef: Codable, Sendable, Hashable {
    public let connectionID: UUID
    public let remoteKey: String

    public init(connectionID: UUID, remoteKey: String) {
        self.connectionID = connectionID
        self.remoteKey = remoteKey
    }
}

/// `(connection, remote key) → local UUID`, with a reverse index.
///
/// The overlay ALWAYS keys by local UUID, so linking or unlinking a project
/// never rewrites an overlay key. This map is the only thing that knows a
/// local item is also `PROJ-412`. A project that has never been linked has no
/// rows here at all.
///
/// Persisted as two parallel arrays rather than a dictionary because
/// `RemoteRef` is not a `String` key: a `[RemoteRef: UUID]` would encode as a
/// flat alternating array anyway, and the explicit shape is readable in the
/// snapshot a person may have to inspect by hand.
public struct LinkMap: Codable, Sendable {
    private var refs: [RemoteRef]
    private var locals: [UUID]

    public init() {
        refs = []
        locals = []
    }

    public var count: Int { refs.count }

    public func localID(for ref: RemoteRef) -> UUID? {
        guard let index = refs.firstIndex(of: ref) else { return nil }
        return locals[index]
    }

    public func remoteRef(for localID: UUID) -> RemoteRef? {
        guard let index = locals.firstIndex(of: localID) else { return nil }
        return refs[index]
    }

    public mutating func link(_ ref: RemoteRef, to localID: UUID) {
        // Relinking must REPLACE, never append: leaving the old row would let a
        // stale remote key resolve to an item that no longer answers to it.
        unlink(localID: localID)
        if let existing = refs.firstIndex(of: ref) {
            refs.remove(at: existing)
            locals.remove(at: existing)
        }
        refs.append(ref)
        locals.append(localID)
    }

    public mutating func unlink(localID: UUID) {
        guard let index = locals.firstIndex(of: localID) else { return }
        refs.remove(at: index)
        locals.remove(at: index)
    }
}
