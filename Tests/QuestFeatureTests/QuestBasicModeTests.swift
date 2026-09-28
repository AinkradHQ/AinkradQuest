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

    @Test("An item opened in basic survives the escalation to advanced")
    func openedItemCarriesAcrossTheModeSwitch() {
        // The bug this guards, which shipped once: basic dropped the item on
        // the claim advanced would re-derive it. It does not — `QuestShell` is
        // rebuilt on the switch, so `surface` starts `.landing` — so tapping an
        // item in Today landed you nowhere near it.
        let store = makeProjectStore(InMemoryProjectRepository())
        let project = store.createProject(name: "Ainkrad", kind: .general, actor: .user)
        let item = try! store.createItem(projectID: project.id, parentID: nil, type: .epic,
                                         title: "Ship basic mode", statusID: "todo", actor: .user)

        store.pendingOpenItem = item
        #expect(store.takePendingOpenItem()?.id == item.id, "advanced must find the target")
        #expect(store.takePendingOpenItem() == nil, "and it is consumed exactly once")
    }

    @Test("With nothing pending, advanced opens on its own landing surface")
    func noPendingItemOpensClean() {
        // The other half: a plain switch to advanced must not jump somewhere
        // out of a stale request.
        let store = makeProjectStore(InMemoryProjectRepository())
        #expect(store.takePendingOpenItem() == nil)
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
