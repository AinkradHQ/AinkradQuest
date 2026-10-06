import Foundation

/// Decides whether the shell's global affordances — the header buttons, the
/// surface tabs and the keyboard chords — may fire.
///
/// This exists because `.ainkradModal` is an OVERLAY scoped to the presenting
/// view's bounds, not a window-modal sheet. An editor presented by `ListSurface`
/// dims only the surface pane; the header above it keeps its own hit region, so
/// without a gate the trash and settings modals can be stacked on top of an open
/// item editor — two presentations, two hidden default actions, one Return key.
///
/// The rule is deliberately one place rather than a `.disabled(...)` repeated per
/// button, so a new global action cannot be added and quietly left ungated.
enum GlobalActionGate {
    /// - Parameters:
    ///   - surfaceModalOpen: a surface below the header is presenting its own
    ///     scoped modal (the item editors in List and Board).
    ///   - shellModalOpen: the shell itself is presenting one (new project,
    ///     attachment picker, command menu, trash, project settings).
    static func globalActionsEnabled(
        surfaceModalOpen: Bool,
        shellModalOpen: Bool
    ) -> Bool {
        !surfaceModalOpen && !shellModalOpen
    }
}
