import SwiftUI
import AinkradAppKit

extension QuestSettingsCatalog {
    /// Existing connections as rows (Remove… on the rail), then the
    /// add-connection form as declared fields.
    static func connections(_ c: Context, _ root: SettingsPath) -> SettingsGroup {
        let group = root.appending("connections")
        var fields: [SettingsField] = c.registry.connections.map { connection in
            let bound = c.store.projectCount(boundTo: connection.id)
            return SettingsField(
                path: group.appending("connection-\(connection.id.uuidString)"),
                label: connection.accountLabel,
                help: "\(connection.provider.settingsTitle) · \(connection.accountIdentifier) · "
                    + "\(bound) project\(bound == 1 ? "" : "s")",
                keywords: ["connection", connection.provider.settingsTitle.lowercased()],
                kind: .action(title: "Remove…") { remove(connection, c) })
        }
        fields += addForm(c, group)
        let notes = [c.registry.persistenceFailure, c.state.connectionMessage].compactMap { $0 }
        return SettingsGroup(
            path: group, title: "Connections",
            footerNote: notes.isEmpty ? "The accounts Quest can reach. Tokens are kept in your Keychain."
                                      : notes.joined(separator: " "),
            fields: fields)
    }

    private static func remove(_ connection: Connection, _ c: Context) {
        guard QuestConfirm.ask(
            "Remove connection?",
            "“\(connection.accountLabel)” and its saved token will be deleted. You will need to "
            + "re-enter the token to reconnect. This cannot be undone.",
            confirm: "Remove") else { return }
        let bound = c.store.projectCount(boundTo: connection.id)
        do {
            try c.registry.removeConnection(connection.id, boundProjectCount: bound)
            // Trashed projects are not counted by the in-use guard; sever them
            // so a restore cannot resurrect a binding to a missing connection.
            c.store.severBindings(toConnection: connection.id, actor: .user)
            c.state.connectionMessage = nil
        } catch let failure as QuestError {
            c.state.connectionMessage = failure.message
        } catch {
            c.state.connectionMessage = error.localizedDescription
        }
    }

    private static let addableProviders: [ProviderKind] = [.jira, .linear, .githubProjects]

    private static func addForm(_ c: Context, _ group: SettingsPath) -> [SettingsField] {
        let state = c.state
        let form = group.appending("add")
        func text(_ id: String, _ label: String, _ help: String?,
                  _ key: WritableKeyPath<ConnectionDraft, String>) -> SettingsField {
            SettingsField(path: form.appending(id), label: label, help: help,
                          kind: .text(Binding(get: { state.draft[keyPath: key] },
                                              set: { state.draft[keyPath: key] = $0 })))
        }
        var fields = [
            SettingsField(
                path: form.appending("provider"), label: "New connection",
                help: "Which service to connect.",
                keywords: ["add", "connection", "jira", "linear", "github"],
                kind: .select(options: addableProviders.map { SettingsOption(id: $0.rawValue, title: $0.settingsTitle) },
                              selection: Binding(get: { state.draft.provider.rawValue },
                                                 set: { if let p = ProviderKind(rawValue: $0) { state.draft.provider = p } }))),
            text("name", "Name", "e.g. Work", \.accountLabel),
            text("account", "Account", "Email or login the provider knows you by.", \.accountIdentifier),
        ]
        if state.draft.requiresBaseURL {
            fields.append(text("site", "Site URL", "e.g. https://you.atlassian.net", \.baseURLText))
        }
        fields.append(SettingsField(
            path: form.appending("token"), label: "Token", help: nil,
            kind: .secure(Binding(get: { state.draft.secret }, set: { state.draft.setManualSecret($0) }))))
        if state.draft.provider == .githubProjects {
            fields.append(SettingsField(
                path: form.appending("gh"), label: "GitHub CLI accounts",
                help: state.picker.errorMessage ?? (state.picker.isLoading
                    ? "Looking…" : "Or use an account the GitHub CLI is already signed in to."),
                kind: .action(title: state.picker.accounts.isEmpty ? "Find accounts" : "Refresh") {
                    Task { await state.picker.load() }
                }))
            for account in state.picker.accounts {
                fields.append(SettingsField(
                    path: form.appending("gh-\(account.id)"),
                    label: "\(account.login) · \(account.host)",
                    help: [account.isActive ? "active" : nil,
                           account.hasRepoScope ? nil : "no repo scope",
                           account.isHealthy ? nil : "unhealthy"].compactMap { $0 }.joined(separator: " · "),
                    kind: .action(title: "Use") {
                        Task {
                            if let picked = await state.picker.pick(account) {
                                state.draft.apply(login: picked.login, token: picked.token)
                            }
                        }
                    }))
            }
        }
        fields.append(SettingsField(
            path: form.appending("submit"), label: "Add connection",
            help: state.draft.validationMessage ?? "Ready to add.",
            kind: .action(title: "Add") { add(c) }))
        return fields
    }

    private static func add(_ c: Context) {
        let draft = c.state.draft
        guard draft.isValid else { c.state.connectionMessage = draft.validationMessage; return }
        do {
            try c.registry.addConnection(
                provider: draft.provider,
                accountLabel: draft.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                accountIdentifier: draft.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: draft.baseURL, secret: draft.secret, tokenProvenance: draft.tokenProvenance)
            c.state.draft = ConnectionDraft(provider: draft.provider)
            c.state.connectionMessage = nil
        } catch let failure as QuestError {
            c.state.connectionMessage = failure.message
        } catch let failure as CredentialError {
            c.state.connectionMessage = failure.message
        } catch {
            c.state.connectionMessage = error.localizedDescription
        }
    }
}
