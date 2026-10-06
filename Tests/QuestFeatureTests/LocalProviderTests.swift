import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("LocalProvider")
struct LocalProviderTests {
    private func makeStore() -> ProjectStore { makeProjectStore(InMemoryProjectRepository()) }

    @Test("the local provider reports the local kind")
    func kind() {
        #expect(LocalProvider(store: makeStore()).kind == .local)
    }

    @Test("listing projects returns the store's live projects")
    func listProjects() async throws {
        let store = makeStore()
        _ = store.createProject(name: "Quest", kind: .software, actor: .user)
        _ = store.createProject(name: "Raven", kind: .general, actor: .user)

        let refs = try await LocalProvider(store: store).listProjects()

        #expect(Set(refs.map(\.name)) == ["Quest", "Raven"])
    }

    @Test("statuses come from the project's own scheme, not a global one")
    func statuses() async throws {
        let store = makeStore()
        let software = store.createProject(name: "Quest", kind: .software, actor: .user)
        let general = store.createProject(name: "Notes", kind: .general, actor: .user)
        let provider = LocalProvider(store: store)

        let softwareStatuses = try await provider.statuses(forProjectKey: software.id.uuidString)
        let generalStatuses = try await provider.statuses(forProjectKey: general.id.uuidString)

        #expect(softwareStatuses.count > generalStatuses.count)
        #expect(softwareStatuses.contains { $0.isDone })
        #expect(generalStatuses.contains { $0.isDone })
    }

    @Test("an unknown project key throws rather than returning empty")
    func unknownProject() async {
        let provider = LocalProvider(store: makeStore())
        await #expect(throws: (any Error).self) {
            try await provider.statuses(forProjectKey: UUID().uuidString)
        }
    }

    @Test("a malformed project key names itself in the error, not a fabricated random id")
    func malformedProjectKeyNamesTheActualBadKey() async {
        let provider = LocalProvider(store: makeStore())
        let badKey = "not-a-uuid"
        await #expect(throws: QuestError.malformedProjectKey(badKey)) {
            try await provider.statuses(forProjectKey: badKey)
        }
    }
}
