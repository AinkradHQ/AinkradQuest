import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("Project binding and repos")
struct ProjectBindingTests {
    private func makeStore() -> ProjectStore { makeProjectStore(InMemoryProjectRepository()) }

    @Test("a new project is unbound")
    func defaultsToUnbound() {
        let store = makeStore()
        let project = store.createProject(name: "Quest", kind: .software, actor: .user)
        #expect(store.overlay.hubConfig().binding(for: project.id) == nil)
        #expect(store.overlay.overlay(for: project.id).repos.isEmpty)
    }

    @Test("binding records the connection and the remote key")
    func bind() throws {
        let store = makeStore()
        let project = store.createProject(name: "Quest", kind: .software, actor: .user)
        let connectionID = UUID()

        try store.bindProject(project.id, to: connectionID, remoteProjectKey: "QST", actor: .user)

        let binding = try #require(store.overlay.hubConfig().binding(for: project.id))
        #expect(binding.connectionID == connectionID)
        #expect(binding.remoteProjectKey == "QST")
    }

    @Test("unbinding clears both the connection and the remote key")
    func unbind() throws {
        let store = makeStore()
        let project = store.createProject(name: "Quest", kind: .software, actor: .user)
        try store.bindProject(project.id, to: UUID(), remoteProjectKey: "QST", actor: .user)

        try store.unbindProject(project.id, actor: .user)

        #expect(store.overlay.hubConfig().binding(for: project.id) == nil)
    }

    @Test("a project attaches several repos, each naming its own connection")
    func multipleRepos() throws {
        let store = makeStore()
        let project = store.createProject(name: "Ainkrad", kind: .software, actor: .user)
        let work = UUID()
        let personal = UUID()

        try store.attachRepo(
            AttachedRepo(
                id: UUID(), connectionID: work,
                owner: "acme", name: "api"),
            to: project.id, actor: .user)
        try store.attachRepo(
            AttachedRepo(
                id: UUID(), connectionID: personal,
                owner: "AhmedMElhalaby", name: "AinkradQuest"),
            to: project.id, actor: .user)

        let updated = store.overlay.overlay(for: project.id).repos
        #expect(updated.map(\.slug) == ["acme/api", "AhmedMElhalaby/AinkradQuest"])
        #expect(Set(updated.map(\.connectionID)) == [work, personal])
    }

    @Test("the same repo on the same connection is refused twice")
    func duplicateRepo() throws {
        let store = makeStore()
        let project = store.createProject(name: "Ainkrad", kind: .software, actor: .user)
        let connectionID = UUID()
        try store.attachRepo(
            AttachedRepo(
                id: UUID(), connectionID: connectionID,
                owner: "a", name: "b"),
            to: project.id, actor: .user)

        #expect(throws: QuestError.duplicateRepo("a/b")) {
            try store.attachRepo(
                AttachedRepo(
                    id: UUID(), connectionID: connectionID,
                    owner: "a", name: "b"),
                to: project.id, actor: .user)
        }
    }

    @Test("the same repo slug on a DIFFERENT connection is allowed")
    func sameSlugDifferentConnection() throws {
        let store = makeStore()
        let project = store.createProject(name: "Ainkrad", kind: .software, actor: .user)
        try store.attachRepo(
            AttachedRepo(
                id: UUID(), connectionID: UUID(),
                owner: "a", name: "b"), to: project.id, actor: .user)
        try store.attachRepo(
            AttachedRepo(
                id: UUID(), connectionID: UUID(),
                owner: "a", name: "b"), to: project.id, actor: .user)
        #expect(store.overlay.overlay(for: project.id).repos.count == 2)
    }

    @Test("detaching removes exactly one repo")
    func detach() throws {
        let store = makeStore()
        let project = store.createProject(name: "Ainkrad", kind: .software, actor: .user)
        let keep = AttachedRepo(id: UUID(), connectionID: UUID(), owner: "a", name: "keep")
        let drop = AttachedRepo(id: UUID(), connectionID: UUID(), owner: "a", name: "drop")
        try store.attachRepo(keep, to: project.id, actor: .user)
        try store.attachRepo(drop, to: project.id, actor: .user)

        try store.detachRepo(drop.id, from: project.id, actor: .user)

        #expect(store.overlay.overlay(for: project.id).repos.map(\.name) == ["keep"])
    }

    @Test("detaching an unknown repo throws")
    func detachUnknown() throws {
        let store = makeStore()
        let project = store.createProject(name: "Ainkrad", kind: .software, actor: .user)
        let ghost = UUID()
        #expect(throws: QuestError.repoNotFound(ghost)) {
            try store.detachRepo(ghost, from: project.id, actor: .user)
        }
    }

    @Test("bound projects are counted per connection")
    func countBound() throws {
        let store = makeStore()
        let connectionID = UUID()
        let a = store.createProject(name: "A", kind: .software, actor: .user)
        let b = store.createProject(name: "B", kind: .software, actor: .user)
        _ = store.createProject(name: "C", kind: .software, actor: .user)
        try store.bindProject(a.id, to: connectionID, remoteProjectKey: "A", actor: .user)
        try store.bindProject(b.id, to: connectionID, remoteProjectKey: "B", actor: .user)

        #expect(store.projectCount(boundTo: connectionID) == 2)
        #expect(store.projectCount(boundTo: UUID()) == 0)
    }

    @Test("a project document written before binding existed still loads")
    func lenientDecoding() throws {
        let json = """
            {"id":"\(UUID().uuidString)","name":"Legacy","summaryText":"","icon":"folder",
             "colorToken":"accent","kind":"software","state":"active",
             "statusScheme":\(String(data: try JSONEncoder().encode(StatusScheme.softwareDefault), encoding: .utf8)!),
             "links":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(json.utf8))
        #expect(project.legacyConnectionID == nil)
        #expect(project.legacyRepos.isEmpty)
    }

    /// Pre-M2A this test proved `mergingLiveConnectionFields` prevented a
    /// stale `Project` draft from reverting a bind/attach made through
    /// `ProjectConnectionSection` while `ProjectSettingsSheet` was open.
    /// M2A moved `connectionID`/`remoteProjectKey`/`repos` out of `Project`
    /// entirely — they now live in `HubConfig`/`ProjectOverlay`, which
    /// `updateProject` never touches — so the hazard this test guarded
    /// against cannot occur any more: writing a stale `Project` draft has
    /// nothing left to clobber. Kept, repurposed to prove exactly that:
    /// binding/attaching through the store, then saving an init-time-stale
    /// `Project` draft, leaves the overlay/hub data untouched.
    @Test("a stale project draft cannot clobber a bind/repo attach, because those fields no longer live on Project")
    func staleDraftDoesNotClobberLiveConnectionFields() throws {
        let store = makeStore()
        let project = store.createProject(name: "Quest", kind: .software, actor: .user)
        // Snapshot the draft exactly as `ProjectSettingsSheet.init` does, BEFORE
        // the bind/attach below — this is what the sheet still holds at Save.
        let staleDraft = project

        let connectionID = UUID()
        try store.bindProject(project.id, to: connectionID, remoteProjectKey: "QST", actor: .user)
        try store.attachRepo(
            AttachedRepo(
                id: UUID(), connectionID: connectionID,
                owner: "acme", name: "api"),
            to: project.id, actor: .user)

        var draft = staleDraft
        draft.name = "Quest Renamed"
        try store.updateProject(draft, actor: .user)

        let saved = try #require(store.openProject(project.id)?.project)
        #expect(saved.name == "Quest Renamed")
        // The overlay/hub data, written through the store before this stale
        // save, survives untouched — `updateProject` has no path to it.
        let binding = try #require(store.overlay.hubConfig().binding(for: project.id))
        #expect(binding.connectionID == connectionID)
        #expect(binding.remoteProjectKey == "QST")
        #expect(store.overlay.overlay(for: project.id).repos.map(\.slug) == ["acme/api"])
    }

    @Test("an AttachedRepo carrying an unrecognized extra field still decodes")
    func attachedRepoToleratesUnknownField() throws {
        let json = """
            {"id":"\(UUID().uuidString)","connectionID":"\(UUID().uuidString)",
             "owner":"acme","name":"api","fromTheFuture":"whatever it is"}
            """
        let repo = try JSONDecoder().decode(AttachedRepo.self, from: Data(json.utf8))
        #expect(repo.slug == "acme/api")
    }

    @Test("a project whose repos array contains an AttachedRepo with an unknown field still loads")
    func projectToleratesAttachedRepoWithUnknownField() throws {
        let repoID = UUID()
        let connectionID = UUID()
        let json = """
            {"id":"\(UUID().uuidString)","name":"Legacy","summaryText":"","icon":"folder",
             "colorToken":"accent","kind":"software","state":"active",
             "statusScheme":\(String(data: try JSONEncoder().encode(StatusScheme.softwareDefault), encoding: .utf8)!),
             "links":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
             "repos":[{"id":"\(repoID.uuidString)","connectionID":"\(connectionID.uuidString)",
                       "owner":"acme","name":"api","fromTheFuture":"whatever it is"}]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(json.utf8))
        #expect(project.legacyRepos.map(\.slug) == ["acme/api"])
    }

    @Test("severing clears bindings on live AND trashed projects")
    func severBindings() throws {
        let store = makeStore()
        let connectionID = UUID()
        let live = store.createProject(name: "Live", kind: .software, actor: .user)
        let trashed = store.createProject(name: "Trashed", kind: .software, actor: .user)
        let other = store.createProject(name: "Other", kind: .software, actor: .user)
        let otherConnection = UUID()
        try store.bindProject(live.id, to: connectionID, remoteProjectKey: "L", actor: .user)
        try store.bindProject(trashed.id, to: connectionID, remoteProjectKey: "T", actor: .user)
        try store.bindProject(other.id, to: otherConnection, remoteProjectKey: "O", actor: .user)
        try store.deleteProject(trashed.id, actor: .user)

        store.severBindings(toConnection: connectionID, actor: .user)

        #expect(store.overlay.hubConfig().binding(for: live.id) == nil)
        // The trashed one is the whole reason this method exists: restoring it
        // must not resurrect a binding to a deleted connection.
        #expect(store.overlay.hubConfig().binding(for: trashed.id) == nil)
        // A project on a DIFFERENT connection is untouched.
        #expect(store.overlay.hubConfig().binding(for: other.id)?.connectionID == otherConnection)
    }

    /// Bind/unbind/attach/detach/sever all moved to writing the overlay/hub
    /// stores directly and stopped routing through `updateProject` — which is
    /// where the activity log used to get appended. Each of these five still
    /// takes an `actor:` parameter; this pins that it is not silently unused.
    @Test("binding, attaching, detaching, and severing all record activity")
    func recordsActivity() throws {
        let store = makeStore()
        let project = store.createProject(name: "Quest", kind: .software, actor: .user)
        let connectionID = UUID()

        try store.bindProject(project.id, to: connectionID, remoteProjectKey: "QST", actor: .user)
        #expect(store.activity(for: project.id).contains { $0.summary.contains("bound") })

        let repo = AttachedRepo(id: UUID(), connectionID: connectionID, owner: "acme", name: "api")
        try store.attachRepo(repo, to: project.id, actor: .user)
        #expect(store.activity(for: project.id).contains { $0.summary.contains("attached repo acme/api") })

        try store.detachRepo(repo.id, from: project.id, actor: .user)
        #expect(store.activity(for: project.id).contains { $0.summary.contains("detached repo acme/api") })

        try store.unbindProject(project.id, actor: .user)
        #expect(store.activity(for: project.id).contains { $0.summary.contains("unbound") })

        try store.bindProject(project.id, to: connectionID, remoteProjectKey: "QST", actor: .user)
        store.severBindings(toConnection: connectionID, actor: .user)
        #expect(store.activity(for: project.id).contains { $0.summary.contains("severed") })
    }
}
