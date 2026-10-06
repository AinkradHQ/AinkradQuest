/// The shortcut table, in one place. Two commands silently claiming one
/// chord is invisible to manual testing — whichever SwiftUI resolves last
/// wins — so `duplicates(in:)` is asserted empty by a test instead.
struct KeyBindings: Sendable {
    struct Modifiers: OptionSet, Sendable, Hashable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
    }

    static let all: [KeyBinding] = [
        KeyBinding(id: "commandMenu", key: "k", modifiers: .command, label: "Commands"),
        KeyBinding(id: "newItem", key: "n", modifiers: .command, label: "New item"),
        KeyBinding(id: "newProject", key: "n", modifiers: [.command, .shift], label: "New project"),
        KeyBinding(id: "focusSearch", key: "f", modifiers: .command, label: "Search"),
    ]

    /// Chord descriptions claimed by more than one binding, sorted for a
    /// stable failure message.
    static func duplicates(in bindings: [KeyBinding]) -> [String] {
        var counts: [String: Int] = [:]
        for binding in bindings { counts[binding.chord, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.keys.sorted()
    }

    static func binding(_ id: String) -> KeyBinding? {
        all.first { $0.id == id }
    }
}

struct KeyBinding: Equatable, Sendable {
    let id: String
    let key: Character
    let modifiers: KeyBindings.Modifiers
    let label: String

    init(id: String, key: Character, modifiers: KeyBindings.Modifiers, label: String) {
        self.id = id
        self.key = key
        self.modifiers = modifiers
        self.label = label
    }

    /// Conventional macOS order: ⌃⌥⇧⌘ then the key, uppercased.
    var chord: String {
        var text = ""
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(key).uppercased()
    }
}
