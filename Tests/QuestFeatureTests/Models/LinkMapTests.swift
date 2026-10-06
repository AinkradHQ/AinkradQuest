import Foundation
import Testing

@testable import QuestFeature

@Suite("Link map and hub config")
struct LinkMapTests {
    @Test("a linked ref resolves both ways")
    func bothDirections() {
        var map = LinkMap()
        let ref = RemoteRef(connectionID: UUID(), remoteKey: "QST-1")
        let local = UUID()
        map.link(ref, to: local)

        #expect(map.localID(for: ref) == local)
        #expect(map.remoteRef(for: local) == ref)
    }

    @Test("the same remote key on two connections maps to two different items")
    func scopedByConnection() {
        var map = LinkMap()
        let a = RemoteRef(connectionID: UUID(), remoteKey: "QST-1")
        let b = RemoteRef(connectionID: UUID(), remoteKey: "QST-1")
        let localA = UUID()
        let localB = UUID()
        map.link(a, to: localA)
        map.link(b, to: localB)

        // Two Jira sites can both have a QST-1. They are not the same work.
        #expect(map.localID(for: a) == localA)
        #expect(map.localID(for: b) == localB)
        #expect(map.count == 2)
    }

    @Test("unlinking one item leaves the others")
    func unlink() {
        var map = LinkMap()
        let keep = RemoteRef(connectionID: UUID(), remoteKey: "KEEP")
        let drop = RemoteRef(connectionID: UUID(), remoteKey: "DROP")
        let keepID = UUID()
        let dropID = UUID()
        map.link(keep, to: keepID)
        map.link(drop, to: dropID)

        map.unlink(localID: dropID)

        #expect(map.localID(for: drop) == nil)
        #expect(map.remoteRef(for: dropID) == nil)
        #expect(map.localID(for: keep) == keepID)
    }

    @Test("relinking a local id replaces its old ref rather than orphaning it")
    func relink() {
        var map = LinkMap()
        let local = UUID()
        let old = RemoteRef(connectionID: UUID(), remoteKey: "OLD")
        let new = RemoteRef(connectionID: UUID(), remoteKey: "NEW")
        map.link(old, to: local)
        map.link(new, to: local)

        // The reverse index must not keep pointing at OLD, or a later lookup
        // resolves a key that no longer maps to anything.
        #expect(map.remoteRef(for: local) == new)
        #expect(map.localID(for: old) == nil)
        #expect(map.count == 1)
    }

    @Test("the map round-trips through JSON")
    func roundTrip() throws {
        var map = LinkMap()
        let ref = RemoteRef(connectionID: UUID(), remoteKey: "QST-9")
        let local = UUID()
        map.link(ref, to: local)

        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode(LinkMap.self, from: data)

        #expect(decoded.localID(for: ref) == local)
        #expect(decoded.remoteRef(for: local) == ref)
    }

    @Test("hub config binds and unbinds a project")
    func binding() {
        var config = HubConfig()
        let project = UUID()
        let connection = UUID()
        config.bind(project, to: ProjectBinding(connectionID: connection, remoteProjectKey: "QST"))

        #expect(config.binding(for: project)?.remoteProjectKey == "QST")
        #expect(config.projectIDs(boundTo: connection) == [project])

        config.unbind(project)
        #expect(config.binding(for: project) == nil)
        #expect(config.projectIDs(boundTo: connection).isEmpty)
    }

    @Test("hub config counts every project on a connection, trashed or not")
    func boundProjects() {
        var config = HubConfig()
        let connection = UUID()
        let a = UUID()
        let b = UUID()
        config.bind(a, to: ProjectBinding(connectionID: connection, remoteProjectKey: "A"))
        config.bind(b, to: ProjectBinding(connectionID: connection, remoteProjectKey: "B"))
        config.bind(UUID(), to: ProjectBinding(connectionID: UUID(), remoteProjectKey: "C"))

        // HubConfig knows nothing about trash — it is routing, not state. The
        // caller decides which of these count for a delete guard.
        #expect(Set(config.projectIDs(boundTo: connection)) == [a, b])
    }

    @Test("hub config persists bindings keyed by uuidString, not raw UUID")
    func bindingsKeyedByUUIDString() throws {
        var config = HubConfig()
        let project = UUID()
        let connection = UUID()
        config.bind(project, to: ProjectBinding(connectionID: connection, remoteProjectKey: "QST"))

        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let bindings = try #require(object?["bindings"] as? [String: Any])

        #expect(bindings[project.uuidString] != nil)

        let decoded = try JSONDecoder().decode(HubConfig.self, from: data)
        #expect(decoded.binding(for: project)?.remoteProjectKey == "QST")
    }
}
