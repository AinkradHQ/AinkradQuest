import SwiftUI
import Foundation
import Observation
import AinkradAppKit

/// The add/edit form's state, split out of the view so validation is testable
/// without a view host — the same split `ProjectSettingsValidationTests` uses.
public struct ConnectionDraft: Equatable {
    public var provider: ProviderKind
    public var accountLabel: String = ""
    public var accountIdentifier: String = ""
    public var baseURLText: String = ""
    public var secret: String = ""
    /// Set when `secret` was filled in by picking a `gh` account rather than
    /// typing a token. Reset to `.manual` the moment the user edits the
    /// secret field by hand, so a stale pick never gets credited as CLI-backed.
    public var tokenProvenance: TokenProvenance = .manual

    public init(provider: ProviderKind) {
        self.provider = provider
    }

    /// Whether this provider is addressed by site. Jira is per-site and GitHub
    /// may be Enterprise; Linear is a single host.
    public var requiresBaseURL: Bool {
        provider == .jira
    }

    public var baseURL: URL? {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme != nil, url.host != nil
        else { return nil }
        return url
    }

    public var validationMessage: String? {
        func blank(_ value: String) -> Bool {
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if blank(accountLabel) { return "Give this account a name." }
        if blank(accountIdentifier) { return "Enter the account's email or login." }
        if requiresBaseURL && blank(baseURLText) {
            return "Jira needs the site URL, e.g. https://you.atlassian.net"
        }
        if !blank(baseURLText) && baseURL == nil { return "That site URL is not valid." }
        if blank(secret) { return "A token is required." }
        return nil
    }

    public var isValid: Bool { validationMessage == nil }

    /// Applies a successful `gh` account pick: fills the identifier and
    /// secret and marks their provenance as CLI-backed.
    public mutating func apply(login: String, token: String) {
        accountIdentifier = login
        secret = token
        tokenProvenance = .githubCLI
    }

    /// Writes a hand-typed secret and disowns any previous `gh` pick — a
    /// token pulled from `gh` that the user then types over is no longer a
    /// `gh` token, and a future refresh path must not try to re-pull it from
    /// the CLI. Extracted so this rule is unit-testable on its own, since
    /// `ConnectionEditor.secretBinding` (the only call site today) needs a
    /// view host to exercise directly.
    public mutating func setManualSecret(_ value: String) {
        secret = value
        tokenProvenance = .manual
    }
}

/// Backs the "pick a `gh` account" alternative to typing a token, for the
/// GitHub Projects provider only. Split out of `ConnectionEditor` so the
/// logic — mapping an account pick or a `GitHubCLIError` to draft fields and
/// display text — is testable without a view host, the same split
/// `ConnectionDraft` gets.
///
/// `GitHubAccountSource.accounts()` and `.token(for:)` shell out and block, so
/// every call into `source` here runs off the main actor (`Task.detached`)
/// and only the result hop back onto it — a blocking subprocess on the main
/// actor would freeze the window.
@MainActor
@Observable
public final class GitHubAccountPickerState {
    public private(set) var accounts: [GitHubAccount] = []
    /// True while either `accounts()` or `token(for:)` is running off-actor.
    public private(set) var isLoading = false
    /// `.cliNotInstalled` and `.notLoggedIn` are expected, common states, not
    /// rare errors — their `.message` is already actionable, so it is shown
    /// here verbatim and the user carries on with manual entry.
    public private(set) var errorMessage: String?

    /// Builds the source lazily rather than holding one directly: the real
    /// `GitHubCLI.init()` itself can shell out (locating the binary via
    /// `/usr/bin/which` when it is not at a known path), so even
    /// CONSTRUCTING the real conformance must happen off the main actor.
    /// Defaults to the real CLI; tests inject `InMemoryGitHubAccountSource`.
    private let makeSource: @Sendable () throws -> any GitHubAccountSource

    public init(makeSource: @escaping @Sendable () throws -> any GitHubAccountSource = { try GitHubCLI() }) {
        self.makeSource = makeSource
    }

    public convenience init(source: any GitHubAccountSource) {
        self.init(makeSource: { source })
    }

    /// Loads the accounts `gh` already knows about. Safe to call repeatedly
    /// (e.g. a "Refresh" action) — each call replaces the previous result.
    public func load() async {
        isLoading = true
        errorMessage = nil
        let makeSource = self.makeSource
        let outcome = await Task.detached {
            Result { try makeSource().accounts() }
        }.value
        isLoading = false
        switch outcome {
        case .success(let accounts):
            self.accounts = accounts
        case .failure(let error):
            self.accounts = []
            self.errorMessage = Self.message(for: error)
        }
    }

    /// Fetches the token for `account`. Returns the login and token to write
    /// into the draft on success (`pick(_:into:)` on `ConnectionDraft` does
    /// that), or `nil` on failure — leaving the draft untouched, since the
    /// caller keeps whatever was already typed — with the failure surfaced
    /// through `errorMessage` instead.
    ///
    /// Returns a plain value rather than taking `draft` `inout` because an
    /// `inout` binding cannot cross the `await` this method needs.
    public func pick(_ account: GitHubAccount) async -> (login: String, token: String)? {
        isLoading = true
        errorMessage = nil
        let makeSource = self.makeSource
        let outcome = await Task.detached {
            Result { try makeSource().token(for: account) }
        }.value
        isLoading = false
        switch outcome {
        case .success(let token):
            return (account.login, token)
        case .failure(let error):
            self.errorMessage = Self.message(for: error)
            return nil
        }
    }

    private static func message(for error: Error) -> String {
        // `.message`, never `.localizedDescription`, matching every other
        // `GitHubCLIError` call site in this codebase.
        (error as? GitHubCLIError)?.message ?? error.localizedDescription
    }
}

/// Manage the accounts Quest can reach. One row per connection, showing which
/// provider it speaks to and how many projects are bound to it.
///
/// Presented inside `QuestSettingsView`'s stack, so it renders a
/// `AinkradSectionFrame` rather than owning a window. The add-connection
/// editor itself, though, is presented by the PARENT: `.ainkradModal` is an
/// overlay that renders in the modified view's own bounds, and this view's
/// bounds are a narrow, offset section box — attaching the modal here (as it
/// once was) clipped it off the window's left edge. So `draft`/`draftToken`
/// are hoisted to `QuestSettingsView` via `@Binding`, the same shape
/// `ProjectSettingsSheet` uses to hoist `pendingSchemePlan` out of
/// `StatusSchemeEditor`: this view remains the only WRITER of the draft, the
/// parent only reads it to know what to present, and it presents from its own
/// full-size root instead.
struct ConnectionsSettings: View {
    @Bindable var registry: ConnectionRegistry
    let store: ProjectStore
    /// Same contract as `ProjectSettingsSheet`: this view never presents its
    /// own error UI, it reports upward.
    let report: (String, AinkradStatus) -> Void

    /// The pending add-connection draft, and its `.id(...)` token — both
    /// owned in shape (written only here) but stored at the parent so the
    /// parent can present the editor from its own root. See the type-level
    /// doc comment above for why.
    @Binding var draft: ConnectionDraft?
    @Binding var draftToken: UUID
    /// The connection awaiting an irreversible delete — one piece of state,
    /// matching `TrashView.pendingPurge`, so two confirm dialogs can never be
    /// up at once. Deleting a HEALTHY, unbound connection destroys its
    /// Keychain secret on the spot; the in-use guard below only protects the
    /// bound case, so this is the only thing standing between one click and
    /// a token the user has to re-enter from scratch.
    @State private var pendingRemoval: Connection?

    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        AinkradSectionFrame(title: "Connections") {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                if let failure = registry.persistenceFailure {
                    Text(failure).foregroundStyle(theme.foreground.opacity(0.7))
                }
                ForEach(registry.connections) { connection in
                    row(connection)
                }
                AinkradButton(title: "Add Connection…", style: .secondary) {
                    draftToken = UUID()
                    draft = ConnectionDraft(provider: .linear)
                }
            }
        }
        // Attached at this view's root, matching `TrashView`: the kit dims
        // and centres the dialog within the view it modifies, so an inner
        // attachment (e.g. on a single row) would scope the scrim to that row.
        .ainkradConfirmDialog(isPresented: Binding(get: { pendingRemoval != nil },
                                                   set: { if !$0 { pendingRemoval = nil } }),
                              title: "Remove connection?",
                              message: pendingRemoval.map {
                                  "“\($0.accountLabel)” and its saved token will be deleted. "
                                      + "You will need to re-enter the token to reconnect. This cannot be undone."
                              } ?? "",
                              confirmTitle: "Remove",
                              isDestructive: true) {
            if let connection = pendingRemoval {
                performRemoval(connection)
            }
            pendingRemoval = nil
        }
    }

    private func row(_ connection: Connection) -> some View {
        let bound = store.projectCount(boundTo: connection.id)
        return AinkradFormRow(title: connection.accountLabel,
                              help: "\(connection.provider.rawValue) · \(connection.accountIdentifier) · \(bound) project\(bound == 1 ? "" : "s")") {
            AinkradButton(title: "Remove", style: .secondary) {
                // Opens the confirm dialog rather than removing directly: a
                // healthy, unbound connection's Keychain secret would
                // otherwise be destroyed on a single click, with no way back
                // short of re-entering the token from scratch. The in-use
                // guard inside `performRemoval` still runs after confirming —
                // this step is additional, not a replacement for it.
                pendingRemoval = connection
            }
        }
    }

    private func performRemoval(_ connection: Connection) {
        let bound = store.projectCount(boundTo: connection.id)
        do {
            try registry.removeConnection(connection.id, boundProjectCount: bound)
            // The guard above only counts LIVE projects, deliberately: a
            // connection you can never delete because something sits forgotten
            // in the trash is a worse failure than a stale field. So the
            // trashed ones are severed here instead — otherwise restoring a
            // project from trash would resurrect a `connectionID` pointing at
            // a connection that no longer exists.
            store.severBindings(toConnection: connection.id, actor: .user)
        } catch let failure as QuestError {
            // The in-use refusal is the COMMON case and must be shown, not
            // swallowed — otherwise the button looks broken.
            report(failure.message, .danger)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }
}

/// Add-connection form. A form with a provider picker restricted to the three
/// real providers (never `.local`, which is not something anyone adds), text
/// fields bound to the draft, a masked secret field, and inline validation.
///
/// Presented through `.ainkradModal`, which injects no `DismissAction` — this
/// view must never reach for `@Environment(\.dismiss)`. Closing happens via
/// `onClose`, called as the LAST statement of a path.
struct ConnectionEditor: View {
    @State private var draft: ConnectionDraft
    let registry: ConnectionRegistry
    let report: (String, AinkradStatus) -> Void
    let onClose: () -> Void

    @Environment(\.ainkradTheme) private var theme

    /// Backs the "pick a gh account" alternative, GitHub Projects only. Owned
    /// here (not hoisted) — it holds no data that needs to survive this
    /// editor closing, unlike `draft` itself.
    @State private var picker: GitHubAccountPickerState

    /// Providers a user can actually add a connection for. `.local` is the
    /// native tracker, never something anyone connects to.
    private static let addableProviders: [ProviderKind] = [.jira, .linear, .githubProjects]

    init(draft: ConnectionDraft, registry: ConnectionRegistry,
         report: @escaping (String, AinkradStatus) -> Void,
         onClose: @escaping () -> Void,
         accountSource: (any GitHubAccountSource)? = nil) {
        _draft = State(initialValue: draft)
        self.registry = registry
        self.report = report
        self.onClose = onClose
        if let accountSource {
            _picker = State(initialValue: GitHubAccountPickerState(source: accountSource))
        } else {
            _picker = State(initialValue: GitHubAccountPickerState())
        }
    }

    /// Any manual edit to the secret field disowns a previous `gh` pick — a
    /// stale pick must never be credited as CLI-backed once the user has
    /// typed over it.
    private var secretBinding: Binding<String> {
        Binding(get: { draft.secret }, set: { draft.setManualSecret($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionHeader(title: "Add connection", subtitle: nil)

            AinkradFormRow(title: "Provider") {
                AinkradSegmentedPicker(items: Self.addableProviders, selection: $draft.provider) {
                    $0.settingsTitle
                }
            }
            AinkradFormRow(title: "Name") {
                AinkradTextField(text: $draft.accountLabel, placeholder: "e.g. Work")
            }
            AinkradFormRow(title: "Account", help: "Email or login the provider knows you by.") {
                AinkradTextField(text: $draft.accountIdentifier, placeholder: "you@example.com")
            }
            if draft.requiresBaseURL {
                AinkradFormRow(title: "Site URL") {
                    AinkradTextField(text: $draft.baseURLText, placeholder: "https://you.atlassian.net")
                }
            }
            AinkradFormRow(title: "Token") {
                AinkradSecureField(text: secretBinding, placeholder: "Token")
            }

            // Additive, never a replacement: the manual token field above is
            // untouched, and this is the only path for a provider `gh` does
            // not know. GitHub Projects only.
            if draft.provider == .githubProjects {
                githubAccountPicker
            }

            if let message = draft.validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(theme.foreground.opacity(0.7))
            }

            HStack {
                AinkradButton(title: "Cancel", style: .secondary, action: onClose)
                Spacer()
                AinkradButton(title: "Add", style: .primary, action: submit)
                    .disabled(!draft.isValid)
            }
        }
        .frame(width: 420)
        .foregroundStyle(theme.foreground)
        .onSubmit(submit)
        // `AinkradButton` carries no keyboard shortcut, so the `.defaultAction`
        // the old `Button("Add")` would have had is otherwise lost — with no
        // text field focused there would be nothing for Return to do.
        .background(defaultActionSubmit)
    }

    /// Inline expansion, not a modal: `.ainkradModal` renders in the MODIFIED
    /// view's own bounds, and this editor is already the thing hoisted to
    /// the settings root to avoid exactly that clipping — nesting a second
    /// modal inside it would reintroduce the bug this file's own history
    /// fixed. A section within the existing form is enough.
    private var githubAccountPicker: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack {
                Text("Or use a gh account")
                    .font(.caption)
                    .foregroundStyle(theme.foreground.opacity(0.7))
                Spacer()
                if picker.isLoading {
                    // A dead-looking button is worse than a spinner — the
                    // subprocess is fast, but not instant.
                    AinkradSpinner(size: 14)
                } else {
                    AinkradButton(title: picker.accounts.isEmpty ? "Find accounts" : "Refresh", style: .secondary) {
                        Task { await picker.load() }
                    }
                }
            }

            ForEach(picker.accounts) { account in
                AinkradButton(title: accountTitle(account), style: .secondary) {
                    Task {
                        if let picked = await picker.pick(account) {
                            draft.apply(login: picked.login, token: picked.token)
                        }
                    }
                }
                .disabled(picker.isLoading)
            }

            // `.cliNotInstalled` / `.notLoggedIn` land here too — they are
            // expected, common states, not rare errors, and their `.message`
            // already says what to do next. Shown via the same inline-message
            // styling as `draft.validationMessage`, not a new modal.
            if let message = picker.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(theme.foreground.opacity(0.7))
            }
        }
    }

    /// Enough detail to choose: login, host (an Enterprise account reads
    /// differently from github.com), which is active, and an upfront warning
    /// when the account cannot work — beats a confusing failure later.
    private func accountTitle(_ account: GitHubAccount) -> String {
        var title = "\(account.login) · \(account.host)"
        if account.isActive { title += " · active" }
        if !account.hasRepoScope { title += " · no repo scope" }
        if !account.isHealthy { title += " · unhealthy" }
        return title
    }

    /// Return-with-nothing-focused submits, exactly as `ItemEditor`'s
    /// `defaultActionSave` does.
    private var defaultActionSubmit: some View {
        Button("") { submit() }
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func submit() {
        guard draft.isValid else { return }
        do {
            try registry.addConnection(provider: draft.provider,
                                       accountLabel: draft.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                                       accountIdentifier: draft.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
                                       baseURL: draft.baseURL,
                                       secret: draft.secret,
                                       tokenProvenance: draft.tokenProvenance)
            // LAST statement on this path — everything after it would run in an
            // unmounted subtree.
            onClose()
        } catch let failure as QuestError {
            report(failure.message, .danger)
        } catch let failure as CredentialError {
            report(failure.message, .danger)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }
}

extension ProviderKind {
    /// The label the settings picker shows. Local to this file because it is a
    /// UI string, not part of the persisted vocabulary.
    var settingsTitle: String {
        switch self {
        case .local: "Local"
        case .jira: "Jira"
        case .linear: "Linear"
        case .githubProjects: "GitHub Projects"
        }
    }
}
