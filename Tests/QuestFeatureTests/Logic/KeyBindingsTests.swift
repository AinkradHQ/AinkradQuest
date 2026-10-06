import Testing

@testable import QuestFeature

@Suite("KeyBindings")
struct KeyBindingsTests {
    @Test("no chord is claimed by two commands")
    func noDuplicates() {
        #expect(KeyBindings.duplicates(in: KeyBindings.all).isEmpty)
    }

    @Test("duplicate detection actually detects one")
    func detectsDuplicate() {
        let a = KeyBinding(id: "a", key: "k", modifiers: .command, label: "A")
        let b = KeyBinding(id: "b", key: "k", modifiers: .command, label: "B")
        #expect(KeyBindings.duplicates(in: [a, b]) == ["⌘K"])
    }

    @Test("the same key with different modifiers is not a duplicate")
    func modifiersDistinguish() {
        let a = KeyBinding(id: "a", key: "n", modifiers: .command, label: "A")
        let b = KeyBinding(id: "b", key: "n", modifiers: [.command, .shift], label: "B")
        #expect(KeyBindings.duplicates(in: [a, b]).isEmpty)
    }

    @Test("chords render in the conventional modifier order")
    func chordRendering() {
        #expect(
            KeyBinding(id: "x", key: "n", modifiers: [.command, .shift], label: "X").chord
                == "⇧⌘N")
        #expect(KeyBinding(id: "y", key: "k", modifiers: .command, label: "Y").chord == "⌘K")
    }

    @Test("the shell's four commands are all present with labels")
    func table() {
        let ids = Set(KeyBindings.all.map(\.id))
        #expect(ids == ["commandMenu", "newItem", "newProject", "focusSearch"])
        #expect(KeyBindings.all.allSatisfy { !$0.label.isEmpty })
    }
}
