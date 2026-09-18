import Testing
import SwiftUI
import AinkradAppKit
@testable import QuestFeature

/// Quest's basic mode: Today, without the shell around it.
@Suite("Quest — basic mode")
@MainActor
struct QuestBasicModeTests {

    @Test("Quest opts into modes, so the host's cast finds it")
    func optsIntoModes() {
        // The host never asks an app whether it has a basic mode; it casts. If
        // this conformance is ever dropped, Quest silently becomes
        // advanced-only with nothing else failing.
        #expect((QuestApp.self as Any) as? AinkradAppModes.Type != nil)
    }

    @Test("Rendering basic mode opens no project document")
    func basicOpensNoProjectDocument() {
        // Quest's latency criterion. `ProjectStore.openProject` reads a
        // project's document off disk and caches it in `documents`; the four
        // advanced surfaces each need one, and Today does not. Opening Quest to
        // glance at what is on must not pay for a document it will not show.
        let repository = InMemoryProjectRepository()
        let store = makeProjectStore(repository)
        _ = store.createProject(name: "Ainkrad", kind: .general, actor: .user)
        _ = store.createProject(name: "Optimus", kind: .general, actor: .user)
        store.documents.removeAll()

        // `.body` rather than just the initializer: constructing a SwiftUI
        // value runs nothing, so an assertion on the un-evaluated view would
        // pass even if basic mode did open every document.
        _ = QuestBasicView(store: store).body

        #expect(store.documents.isEmpty,
                "basic mode must not open a project document")
    }

    @Test("Basic mode reads the project count without opening the projects")
    func subtitleIsIndexOnly() {
        // The count comes from the index, which is already loaded — reading it
        // must not become a reason to open each project.
        let store = makeProjectStore(InMemoryProjectRepository())
        _ = store.createProject(name: "Ainkrad", kind: .general, actor: .user)
        store.documents.removeAll()
        _ = QuestBasicView(store: store).body
        #expect(store.projects.count == 1)
        #expect(store.documents.isEmpty)
    }
}
