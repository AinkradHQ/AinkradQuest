import AinkradAppKit
import Foundation
import SwiftUI

/// Binds a project to a connection, and attaches the repos it works out of —
/// which may span several different accounts (the duplicate-repo guard in
/// `ProjectStore.attachRepo` is scoped BY connection, so the same slug can
/// legitimately appear twice here under two different accounts).
///
/// Mounted inside `ProjectSettingsSheet`'s scroll body, same as
/// `StatusSchemeEditor` — it is not its own presented sheet, so it never
/// touches `onClose`/`dismiss` itself.
struct ProjectConnectionSection: View {
    @Bindable var store: ProjectStore
    let registry: ConnectionRegistry
    let project: Project
    let report: (String, AinkradStatus) -> Void

    /// `AinkradSelect` needs a NON-optional binding, so "nothing chosen" is
    /// represented by this sentinel id — a real UUID that matches no
    /// connection — exactly the trick `StatusSchemeEditor.destinations` uses
    /// with its `""` sentinel.
    private static let noConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!  // design-lint: allow force-unwrap constant literal UUID, always valid

    @State private var remoteProjectKeyText: String = ""
    @State private var pendingConnectionSelection: UUID = ProjectConnectionSection.noConnection
    @State private var repoDraft = RepoDraft()

    @Environment(\.ainkradTheme) private var theme

    /// Repos live in the overlay now, not on `Project` — read through
    /// `store.overlay`, never `project.legacyRepos`.
    private var repos: [AttachedRepo] { store.overlay.overlay(for: project.id).repos }

    /// The connection this project is bound to, if any — read through
    /// `HubConfig`, never `project.legacyConnectionID`.
    private var boundConnectionID: UUID? {
        store.overlay.hubConfig().binding(for: project.id)?.connectionID
    }

    private var pendingConnectionID: UUID? {
        pendingConnectionSelection == Self.noConnection ? nil : pendingConnectionSelection
    }

    private func connectionLabel(_ id: UUID) -> String {
        id == Self.noConnection ? "Choose…" : (registry.connection(id)?.accountLabel ?? "Choose…")
    }

    private var repoConnectionBinding: Binding<UUID> {
        Binding(
            get: { repoDraft.connectionID ?? Self.noConnection },
            set: { repoDraft.connectionID = $0 == Self.noConnection ? nil : $0 })
    }

    var body: some View {
        AinkradSectionFrame(title: "Connection") {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                connectionFields
            }
        }
        AinkradSectionFrame(title: "Repos") {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                ForEach(repos) { repo in
                    repoRow(repo)
                }
                attachForm
            }
        }
        // `AinkradButton` carries no keyboard shortcut, so both `.primary`
        // buttons above ("Bind", "Attach") would otherwise leave Return doing
        // nothing with a text field focused — the exact trap
        // `ViewSourceInvariants` guards against. The attach form is the one
        // actively being typed into here, so Return commits it; binding still
        // has its own explicit "Bind" button.
        .background(repoDraft.isValid ? defaultActionAttach : nil)
    }

    private var defaultActionAttach: some View {
        HiddenShortcutButton(.defaultAction) { attach() }
    }

    @ViewBuilder private var connectionFields: some View {
        if registry.connections.isEmpty {
            // No accounts exist at all yet — a picker over an empty list
            // would just look broken, so say so plainly instead.
            Text("No connections yet. Add one under Connections to bind this project.")
                .font(.caption)
                .foregroundStyle(theme.foreground.opacity(0.7))
        } else if let connectionID = boundConnectionID,
            let connection = registry.connection(connectionID)
        {
            AinkradFormRow(
                title: "Bound to",
                help: "\(connection.provider.rawValue) · \(connection.accountLabel)"
            ) {
                AinkradButton(title: "Unbind", style: .secondary, action: unbind)
            }
        } else {
            // A project with no connection is a NATIVE project — the normal
            // case, not an error state.
            Text("Native project — not bound to a connection.")
                .font(.caption)
                .foregroundStyle(theme.foreground.opacity(0.7))
            AinkradFormRow(title: "Account") {
                AinkradSelect(
                    items: [Self.noConnection] + registry.connections.map(\.id),
                    selection: $pendingConnectionSelection,
                    label: connectionLabel)
            }
            AinkradFormRow(
                title: "Remote project key",
                help: "The provider's own key for this project (e.g. \"QST\")."
            ) {
                AinkradTextField(text: $remoteProjectKeyText, placeholder: "QST")
            }
            AinkradButton(title: "Bind", style: .primary, action: bind)
                .disabled(
                    pendingConnectionID == nil
                        || remoteProjectKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func repoRow(_ repo: AttachedRepo) -> some View {
        let accountLabel = registry.connection(repo.connectionID)?.accountLabel ?? "Unknown account"
        return AinkradFormRow(title: repo.slug, help: accountLabel) {
            AinkradButton(title: "Detach", style: .secondary) {
                detach(repo)
            }
        }
    }

    @ViewBuilder private var attachForm: some View {
        AinkradFormRow(title: "Account") {
            AinkradSelect(
                items: [Self.noConnection] + registry.connections.map(\.id),
                selection: repoConnectionBinding,
                label: connectionLabel)
        }
        AinkradFormRow(title: "Repo", help: "owner/name") {
            AinkradTextField(text: $repoDraft.slugText, placeholder: "owner/name")
        }
        AinkradFormRow(title: "Local path", help: "Optional — where it is checked out.") {
            AinkradTextField(text: $repoDraft.localPath, placeholder: "/Users/you/Projects/repo")
        }
        if let message = repoDraft.validationMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.foreground.opacity(0.7))
        }
        AinkradButton(title: "Attach", style: .primary, action: attach)
            .disabled(!repoDraft.isValid)
    }

    private func bind() {
        guard let connectionID = pendingConnectionID else { return }
        let key = remoteProjectKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try store.bindProject(project.id, to: connectionID, remoteProjectKey: key, actor: .user)
            pendingConnectionSelection = Self.noConnection
            remoteProjectKeyText = ""
        } catch {
            report(error.localizedDescription, .danger)
        }
    }

    private func unbind() {
        do {
            try store.unbindProject(project.id, actor: .user)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }

    private func attach() {
        guard let repo = repoDraft.repo(id: UUID()) else { return }
        do {
            try store.attachRepo(repo, to: project.id, actor: .user)
            repoDraft = RepoDraft()
        } catch {
            report(error.localizedDescription, .danger)
        }
    }

    private func detach(_ repo: AttachedRepo) {
        do {
            try store.detachRepo(repo.id, from: project.id, actor: .user)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }
}
