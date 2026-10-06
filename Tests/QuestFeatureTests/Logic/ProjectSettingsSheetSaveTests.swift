import Foundation
import Testing

@testable import QuestFeature

/// Drives `ProjectSettingsSheetWrite.apply` — the exact function
/// `ProjectSettingsSheet.save()` calls to build what it writes — rather than
/// a hand-mirrored copy of `save()`'s logic. There is no SwiftUI hosting
/// harness in this test target for `ProjectSettingsSheet` itself (see
/// `ViewSourceInvariantsTests` for why this codebase source-scans views
/// instead of hosting them), but the write itself is a pure, testable
/// function precisely so this suite CAN drive the real code path instead of
/// reimplementing it.
@MainActor
@Suite("ProjectSettingsSheet.save() write path")
struct ProjectSettingsSheetSaveTests {
    /// Task 5 review (Important 6) asked for a behavioural guard proving
    /// `state`/`links` survive a stale-draft save. The FIRST version of this
    /// test mirrored `save()`'s old body and found a live, pre-existing bug:
    /// a state change or a link added elsewhere while the sheet was open was
    /// silently reverted on Save. Traced concretely by the coordinator: the
    /// MCP `add_link` operation writes with `actor: .agent` entirely outside
    /// the SwiftUI modal stack, so "ask the assistant to attach a PR link,
    /// then hit Save" was a real, reachable data-loss path.
    ///
    /// Fixed not by refreshing the two fields this test happened to catch,
    /// but structurally: `ProjectSettingsSheetWrite.apply` starts from the
    /// LIVE project and overlays only what the sheet's own controls own
    /// (name, summary, icon, colour, kind). `state`/`links`/`archivedAt`/
    /// `statusScheme` — and anything added to `Project` later — pass through
    /// from `live` untouched, so they cannot be reverted by a stale `draft`
    /// no matter what changed elsewhere while the sheet was open.
    @Test("a state change and a link added while the sheet is open survive the write")
    func stateAndLinksSurviveStaleDraftSave() throws {
        let store = makeProjectStore(InMemoryProjectRepository())
        let project = store.createProject(name: "Quest", kind: .software, actor: .user)
        // Snapshot exactly as `ProjectSettingsSheet.init` does.
        let staleDraft = project
        let colorToken = ProjectColorToken.resolve(project.colorToken)

        // Changes made elsewhere — e.g. the coordinator's traced MCP
        // `add_link` path, or the project being paused from another
        // surface — WHILE the sheet is still open holding `staleDraft`.
        try store.setState(project.id, state: .paused, actor: .user)
        try store.addLink(
            to: .project(project.id),
            link: Link(scheme: .url, identifier: "https://example.com", label: "Example"),
            actor: .user)

        // The user edits the name in the sheet, then hits Save.
        var edited = staleDraft
        edited.name = "Quest Renamed"
        let live = try #require(store.openProject(project.id)?.project)
        let toSave = ProjectSettingsSheetWrite.apply(
            draft: edited, colorToken: colorToken,
            validatedName: "Quest Renamed", to: live)
        try store.updateProject(toSave, actor: .user)

        let saved = try #require(store.openProject(project.id)?.project)
        #expect(saved.name == "Quest Renamed")
        #expect(saved.state == .paused)
        #expect(saved.links.count == 1)
    }

    /// The other half of the same guarantee: fields the sheet DOES own are
    /// still written, not accidentally swallowed by reading everything from
    /// `live`.
    @Test("fields the sheet owns — name, summary, icon, colour, kind — are still written")
    func ownedFieldsAreWritten() throws {
        let store = makeProjectStore(InMemoryProjectRepository())
        let project = store.createProject(name: "Quest", kind: .software, actor: .user)
        var draft = project
        draft.name = "Renamed"
        draft.summaryText = "New summary"
        draft.icon = "star"
        draft.kind = .general
        let live = try #require(store.openProject(project.id)?.project)

        let toSave = ProjectSettingsSheetWrite.apply(
            draft: draft, colorToken: .success,
            validatedName: "Renamed", to: live)

        #expect(toSave.name == "Renamed")
        #expect(toSave.summaryText == "New summary")
        #expect(toSave.icon == "star")
        #expect(toSave.kind == .general)
        #expect(toSave.colorToken == ProjectColorToken.success.rawValue)
    }
}
