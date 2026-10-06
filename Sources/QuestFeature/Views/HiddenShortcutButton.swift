import SwiftUI

/// An invisible, zero-size button whose only job is to carry a keyboard
/// shortcut. `AinkradButton` binds no keys, so every Quest form that wants
/// Return to submit (and the shell's global chords) mounts one of these
/// alongside its visible buttons.
struct HiddenShortcutButton: View {
    let shortcut: KeyboardShortcut
    let action: () -> Void

    init(_ shortcut: KeyboardShortcut, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button("", action: action)  // design-lint: allow raw-control kit gap: shortcut carrier
            .keyboardShortcut(shortcut)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}
