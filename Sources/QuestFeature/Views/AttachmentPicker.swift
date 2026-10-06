import AinkradAppKit
import AppKit
import SwiftUI

/// Shown after a project is created when `AttachmentSuggestions.build`
/// returned at least one candidate. Every suggestion starts unchecked — the
/// user opts in, never the other way round. "Attach another folder…" here is
/// a convenience alongside the suggestions, not the only way to reach the
/// picker — `FolderAttachButton` on Overview is the one that is always
/// reachable, independent of whether this sheet ever appears.
struct AttachmentPicker: View {
    @Bindable var store: ProjectStore
    let projectID: UUID
    let suggestions: [AttachmentSuggestion]
    /// The shell's single reporting path, replacing this view's own `error`
    /// string. Toasts are mounted by `.ainkradToastHost()` on `QuestShell`,
    /// outside the modal overlay this picker lives in, so they render above it.
    let report: (String, AinkradStatus) -> Void
    /// Called once the sheet is dismissed, whether or not anything was attached.
    let onDone: () -> Void

    /// Self-themed from the environment: presented inside `NewProjectForm`'s
    /// `.ainkradModal`, which renders in the modified view's own bounds and so
    /// inherits the host-injected theme. No `theme:` parameter to thread.
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typo
    @State private var checked: Set<String> = []

    var body: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                Text("Folders that look like they belong to this project. Nothing is attached until you say so.")
                    .font(AinkradFontResolver.font(.body, typography: typo))
                    .foregroundStyle(theme.foreground)

                // `AinkradCheckbox`, not a raw SwiftUI `Toggle`: the kit draws
                // its own chamfer control and takes a plain `String` label, so
                // the scheme glyph sits beside it rather than inside a `Label`.
                ForEach(suggestions) { suggestion in
                    HStack(spacing: AinkradSpacing.sm) {
                        AinkradIconGlyph(systemName: LinkSymbol.name(for: suggestion.scheme))
                        AinkradCheckbox(isOn: isChecked(suggestion), label: suggestion.label)
                    }
                }

                HStack {
                    AinkradButton(title: "Attach another folder…", style: .ghost, action: attachAnother)
                    Spacer()
                    AinkradButton(title: "Skip", style: .ghost, action: onDone)
                    AinkradButton(title: "Attach selected", style: .primary, action: attachChecked)
                }
            }
        }
        // No padding here: `.ainkradModal` already insets its content by
        // `AinkradSpacing.lg` before capping the width, so a second inset
        // would double it and push the card toward that cap.
        //
        // `AinkradButton` binds no keys, so without this Return did nothing at
        // all in this picker — there is no text field here to give it a
        // meaning. Found by the source invariant, not by anyone using it.
        .background(defaultActionAttach)
    }

    /// Return attaches what is checked, matching every other primary action in
    /// the app. Checking nothing and pressing Return is harmless: `attachChecked`
    /// attaches an empty set and finishes, which is what Skip does.
    private var defaultActionAttach: some View {
        HiddenShortcutButton(.defaultAction) { attachChecked() }
    }

    private func isChecked(_ suggestion: AttachmentSuggestion) -> Binding<Bool> {
        Binding(
            get: { checked.contains(suggestion.id) },
            set: { isOn in
                if isOn { checked.insert(suggestion.id) } else { checked.remove(suggestion.id) }
            })
    }

    /// Attempts every checked suggestion rather than stopping at the first
    /// failure — a checkbox the user ticked should not silently go
    /// unprocessed because an earlier one in the list failed. Failures are
    /// collected and reported together; the sheet only closes once nothing
    /// failed.
    private func attachChecked() {
        let toAttach = suggestions.filter { checked.contains($0.id) }
        var failures: [String] = []
        for suggestion in toAttach {
            if let message = FolderAttachment.attach(
                url: suggestion.url, scheme: suggestion.scheme,
                to: projectID, store: store)
            {
                failures.append("\(suggestion.label): \(message)")
            }
        }
        if failures.isEmpty {
            onDone()
        } else {
            // The sheet deliberately stays open on failure so the ticked
            // suggestions are still visible next to the reported reason.
            report(failures.joined(separator: "; "), .danger)
        }
    }

    /// Opens an `NSOpenPanel` regardless of any granted root — this is a
    /// convenience alongside the suggestions, and (like `FolderAttachButton`)
    /// must not depend on a root being set.
    private func attachAnother() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let message = FolderAttachment.attach(
            url: url,
            scheme: FolderMatch.linkKind(for: url),
            to: projectID, store: store)
        {
            report(message, .danger)
        }
    }
}

/// The escape hatch for attaching a folder to an EXISTING project,
/// independent of any root grant and independent of whether
/// `AttachmentSuggestions.build` ever found anything for this project. Lives
/// on Overview beside the links list (`LinkListView`/`LinkEditor`) so
/// attaching a folder is always reachable, not gated behind a suggestion
/// sheet that may never appear.
struct FolderAttachButton: View {
    @Bindable var store: ProjectStore
    let projectID: UUID
    /// The shell's reporting path, replacing this view's `error` string. No
    /// `theme:` to thread: this view draws only a kit button, which reads
    /// `\.ainkradTheme` from the environment itself.
    let report: (String, AinkradStatus) -> Void

    var body: some View {
        AinkradButton(title: "Attach folder…", style: .secondary, action: attach)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let message = FolderAttachment.attach(
            url: url,
            scheme: FolderMatch.linkKind(for: url),
            to: projectID, store: store)
        {
            report(message, .danger)
        }
    }
}
