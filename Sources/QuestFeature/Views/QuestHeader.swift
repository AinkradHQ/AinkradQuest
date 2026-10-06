import AinkradAppKit
import SwiftUI

/// The shell's top bar: which surface, search, and the three global actions.
///
/// One row, not two. The surface switcher sits where a breadcrumb used to,
/// which is also the only place it needs to be: the sidebar already shows
/// which project is selected, so a trail restating it was a second row of
/// chrome earning nothing.
struct QuestHeader: View {
    @Environment(\.ainkradSkin) private var skin
    @Binding var surface: QuestSurface
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding
    let showsSwitcher: Bool
    /// The gear acts on the selected project, so it is withheld — not merely
    /// inert — when there is none.
    let showsSettings: Bool
    /// False while anything is presented over the app. `.ainkradModal` is a
    /// scoped overlay, so an editor put up by a surface does not cover this
    /// row — the shell has to switch it off explicitly.
    let actionsEnabled: Bool
    let onNew: () -> Void
    let onSettings: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: AinkradSpacing.md) {
            // Leading slot. On Today there is no per-project switcher, so this
            // is empty and the search field carries the row on its own.
            if showsSwitcher {
                AinkradSegmentedPicker(
                    items: SurfaceVisibility.offered(hasProject: true),
                    selection: $surface
                ) { $0.title }
                .transition(.opacity)
            }
            Spacer(minLength: AinkradSpacing.md)
            AinkradSearchField(
                text: $searchText, placeholder: "Search items",
                focus: searchFocused
            )
            .frame(maxWidth: skin.size.s280)
            // The no-`size` initializer, so the button frame comes from the
            // kit's own default rather than a literal here. That overload
            // takes no `tooltip:`, so the hover hint and its VoiceOver
            // equivalent are attached explicitly — `.help` alone is
            // mouse-only, and these three buttons are icon-only.
            iconAction("plus", "New", onNew)
            if showsSettings {
                iconAction("gearshape", "Project settings", onSettings)
                    .transition(.opacity)
            }
            iconAction("trash", "Trash", onTrash)
        }
        .padding(.horizontal, AinkradSpacing.md)
        .padding(.vertical, AinkradSpacing.sm)
        // Covers the search field and the tabs as well as the buttons: switching
        // surface underneath an open editor would leave the editor floating over
        // a pane that no longer owns it.
        .disabled(!actionsEnabled)
        .animation(AinkradMotion.present, value: showsSwitcher)
        .animation(AinkradMotion.present, value: showsSettings)
    }

    private func iconAction(
        _ systemName: String, _ label: String,
        _ action: @escaping () -> Void
    ) -> some View {
        AinkradIconButton(systemName: systemName, action: action)
            .help(label)
            .accessibilityLabel(label)
    }
}
