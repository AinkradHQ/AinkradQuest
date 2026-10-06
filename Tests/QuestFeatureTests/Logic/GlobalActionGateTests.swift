import Testing

@testable import QuestFeature

@Suite("GlobalActionGate")
struct GlobalActionGateTests {
    @Test("with nothing presented the header and chords are live")
    func idleIsEnabled() {
        #expect(
            GlobalActionGate.globalActionsEnabled(
                surfaceModalOpen: false,
                shellModalOpen: false))
    }

    /// The case the branch review found: a scoped overlay covers only the
    /// surface pane, so the header stays clickable unless something stops it.
    @Test("a surface-scoped editor closes the header")
    func surfaceModalDisables() {
        #expect(
            !GlobalActionGate.globalActionsEnabled(
                surfaceModalOpen: true,
                shellModalOpen: false))
    }

    @Test("a shell modal closes the header too")
    func shellModalDisables() {
        #expect(
            !GlobalActionGate.globalActionsEnabled(
                surfaceModalOpen: false,
                shellModalOpen: true))
    }

    @Test("both at once stays disabled")
    func bothDisables() {
        #expect(
            !GlobalActionGate.globalActionsEnabled(
                surfaceModalOpen: true,
                shellModalOpen: true))
    }
}
