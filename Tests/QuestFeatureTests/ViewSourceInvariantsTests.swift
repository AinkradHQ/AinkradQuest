import Foundation
import Testing

@testable import QuestFeature

/// Tripwires for the view-tree traps that M5 hit. Each one names a defect that
/// actually shipped, compiled, and passed every other test in this suite.
///
/// See `ViewSource` for why these read source text instead of running the views.
@Suite("ViewSourceInvariants")
struct ViewSourceInvariantsTests {
    /// A guard on the guard: a wrong path would scan nothing and every
    /// invariant below would pass vacuously, which is the worst outcome
    /// available here — a green suite asserting nothing at all.
    @Test("the scanner actually finds the view files")
    func scannerFindsFiles() throws {
        let files = try ViewSource.load()
        #expect(files.count >= 14, "found only \(files.count) files in \(ViewSource.viewsDirectory.path)")
        #expect(files.contains { $0.name == "QuestShell.swift" })
    }

    /// Trap: `.ainkradModal(isPresented:)` REUSES its content view when the
    /// underlying item changes — unlike `.sheet(item:)`. Without `.id(item.id)`
    /// the stale `@State` draft edits the WRONG item, silently.
    @Test("every item-derived modal is keyed to its item")
    func itemDerivedModalsAreKeyed() throws {
        for file in try ViewSource.load() {
            for start in file.lineNumbers(containing: ".ainkradModal(") {
                let body = ViewSource.block(in: file, from: start)
                // `if let` inside the content is the signal that what renders is
                // derived from an optional item, and so can change identity
                // while the presentation stays up.
                guard body.contains(where: { $0.code.contains("if let ") }) else { continue }
                let keyed = body.contains { $0.code.contains(".id(") }
                #expect(
                    keyed,
                    """
                    \(file.name):\(start) presents item-derived content without `.id(…)`. \
                    `.ainkradModal` reuses its content view across a change of the item, so the \
                    previous item's @State draft would be applied to the new one.
                    """)
            }
        }
    }

    /// Trap: `.ainkradToastHost()` injects its center into its CONTENT's
    /// subtree. A view that applies the modifier to itself and also reads
    /// `\.ainkradToastCenter` resolves above it, gets the `@Entry` default, and
    /// every toast it shows is silently dropped. This shipped in Task 7.
    @Test("no type both mounts the toast host and reads the toast center")
    func toastHostIsNotSelfRead() throws {
        for file in try ViewSource.load() {
            for type in ViewSource.types(in: file) {
                let mounts = type.lines.contains { $0.code.contains(".ainkradToastHost()") }
                let reads = type.lines.contains { $0.code.contains("\\.ainkradToastCenter") }
                #expect(
                    !(mounts && reads),
                    """
                    \(file.name): `\(type.name)` both applies `.ainkradToastHost()` and reads \
                    `\\.ainkradToastCenter`. The read resolves ABOVE the modifier and returns the \
                    @Entry default, so every report() is dropped. Split it: a wrapper applies the \
                    host, an inner view does the reporting.
                    """)
            }
        }
    }

    /// Trap: `.ainkradModal` is an overlay and injects no `DismissAction`, so
    /// `@Environment(\.dismiss)` inside one resolves to a no-op — Cancel and
    /// Save compile, run, and do nothing. Quest presents everything through
    /// `.ainkradModal`, so the honest rule is that no view here uses it at all;
    /// presenters close their own presentations through an `onClose` callback.
    @Test("no view reaches for the environment's dismiss action")
    func noEnvironmentDismiss() throws {
        for file in try ViewSource.load() {
            let sites = file.lineNumbers(containing: "\\.dismiss")
            #expect(
                sites.isEmpty,
                """
                \(file.name):\(sites.map(String.init).joined(separator: ",")) uses \
                `\\.dismiss`. `.ainkradModal` injects no DismissAction — the call would compile \
                and do nothing. Take an `onClose` from the presenter instead.
                """)
        }
    }

    // A trap this suite used to guard here — "ProjectSettingsSheet's save path
    // merges live connection fields before writing", pinning a call to
    // `mergingLiveConnectionFields` — is OBSOLETE as of M2A (Task 5): that
    // helper and its call site are gone. The hazard it guarded against (a
    // stale init-time `Project` draft reverting a bind/repo-attach made while
    // the sheet was open) required `connectionID`/`remoteProjectKey`/`repos`
    // to live ON `Project`. M2A moved them into `HubConfig`/`ProjectOverlay`,
    // which `updateProject` never writes, so a stale `Project` draft has
    // nothing left to clobber — the trap cannot recur by construction, not by
    // this merge step. See `ProjectBindingTests.staleDraftDoesNotClobberLiveConnectionFields`
    // for the coverage that replaces it.

    /// Trap (Task 5 fix round 2): `save()` used to write the sheet's WHOLE
    /// stale `draft` back through `updateProject`, silently reverting any
    /// `state`/`links`/etc. change made elsewhere while the sheet was open —
    /// a live bug the coordinator traced through the MCP `add_link` path.
    /// The fix is structural: `save()` must build what it writes through
    /// `ProjectSettingsSheetWrite.apply`, which starts from the LIVE project
    /// and overlays only the fields the sheet owns, rather than ever handing
    /// `store.updateProject` the bare stale `draft`.
    @Test("ProjectSettingsSheet.save() never writes the bare stale draft")
    func saveNeverWritesBareStaleDraft() throws {
        let found = try ViewSource.load().first { $0.name == "ProjectSettingsSheet.swift" }
        let file = try #require(found, "ProjectSettingsSheet.swift not found in \(ViewSource.viewsDirectory.path)")
        #expect(
            file.contains("ProjectSettingsSheetWrite.apply"),
            """
            ProjectSettingsSheet.swift no longer calls `ProjectSettingsSheetWrite.apply`. That \
            function is what keeps `save()` from writing the sheet's stale `draft` straight \
            through — without it, a state/links/etc. change made elsewhere while the sheet is \
            open is silently reverted on Save.
            """)
        let updatesWithBareDraft = file.lineNumbers(containing: "updateProject(draft,")
        #expect(
            updatesWithBareDraft.isEmpty,
            """
            \(file.name):\(updatesWithBareDraft.map(String.init).joined(separator: ",")) calls \
            `store.updateProject(draft, ...)` directly — the exact shape of the bug this guard \
            exists to catch. Route it through `ProjectSettingsSheetWrite.apply` instead.
            """)
    }

    /// Trap: `ConnectionsSettings` is a SECTION (`AinkradSectionFrame`) sitting
    /// inside `QuestSettingsView`'s stack, not a window or a full-size root.
    /// `.ainkradModal` renders in the MODIFIED VIEW'S OWN BOUNDS — attaching
    /// it to `ConnectionsSettings` itself scoped the overlay to that narrow,
    /// offset section box, clipping the add-connection editor off the
    /// window's left edge. This shipped and passed every other test in this
    /// suite; nothing else pins the modal to the settings root, so
    /// re-attaching `.ainkradModal` inside `ConnectionsSettings.swift` would
    /// reintroduce the clip with all other tests still green.
    @Test("the add-connection modal stays presented from the settings root, not the section")
    func connectionModalIsPresentedFromSettingsRoot() throws {
        let sectionFile = try #require(
            try ViewSource.load().first { $0.name == "ConnectionsSettings.swift" },
            "ConnectionsSettings.swift not found in \(ViewSource.viewsDirectory.path)")
        #expect(
            !sectionFile.contains(".ainkradModal("),
            """
            ConnectionsSettings.swift presents `.ainkradModal` itself again. That view renders as \
            an `AinkradSectionFrame` inside `QuestSettingsView`'s stack — a narrow, offset box, not \
            a window — so the overlay would be clipped off the left edge as it was before this fix. \
            Keep the draft's presentation hoisted to `QuestSettingsView` via the `@Binding` \
            `draft`/`draftToken`, as `ProjectSettingsSheet` hoists `pendingSchemePlan`.
            """)

        let rootFile = try #require(
            try ViewSource.load().first { $0.name == "QuestSettingsView.swift" },
            "QuestSettingsView.swift not found in \(ViewSource.viewsDirectory.path)")
        #expect(
            rootFile.contains(".ainkradModal("),
            """
            QuestSettingsView.swift no longer presents the add-connection modal from the settings \
            root — without it the editor has nowhere full-size to render from.
            """)
    }

    /// Trap: `AinkradButton` carries NO keyboard shortcut — in the whole kit
    /// only `AinkradModal`/`AinkradDrawer` bind keys. Migrating off SwiftUI's
    /// `Button` therefore drops every `.defaultAction` silently. This is the
    /// one that survived four tasks: Task 12 found the cause, but nothing swept
    /// back over `NewProjectForm`, migrated in Task 8, which had lost
    /// Return-to-create.
    @Test("a primary button is always reachable from the keyboard")
    func primaryButtonsHaveADefaultAction() throws {
        for file in try ViewSource.load() {
            for type in ViewSource.types(in: file) {
                let hasPrimary = type.lines.contains { $0.code.contains("style: .primary") }
                guard hasPrimary else { continue }
                let hasDefault = type.lines.contains { $0.code.contains(".defaultAction") }
                #expect(
                    hasDefault,
                    """
                    \(file.name): `\(type.name)` has a `.primary` AinkradButton but no \
                    `.keyboardShortcut(.defaultAction)`. AinkradButton binds no keys, so Return \
                    does nothing here. Add a hidden default-action Button, as ItemEditor does.
                    """)
            }
        }
    }
}
