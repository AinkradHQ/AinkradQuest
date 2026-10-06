import AinkradAppKit
import SwiftUI

/// The kinds a user may pick, in offer order. Named rather than `allCases` so
/// `.unknown` — a value only a malformed document can produce — is never
/// offered as something to create.
private let offeredSchemes: [LinkScheme] = [.repo, .folder, .file, .url, .branch, .pr, .commit]

/// Which schemes require a repo. Mirrors `LinkValidation`'s own set; kept here
/// only to decide whether to SHOW the field, never to decide validity.
private let repoScopedSchemes: Set<LinkScheme> = [.branch, .pr, .commit]

struct LinkEditor: View {
    @Bindable var store: ProjectStore
    /// What this editor attaches to — a project or one work item.
    let target: LinkTarget
    /// The shell's single reporting path. This view owns NO error string: the
    /// old `@State var error` had to be cleared on every success so a stale
    /// failure could not outlive the input that caused it. A toast expires on
    /// its own, so the clear-on-success rule is preserved by construction —
    /// which is why the success branches below deliberately report nothing.
    let report: (String, AinkradStatus) -> Void

    @State private var scheme: LinkScheme = .repo
    @State private var identifier = ""
    @State private var label = ""
    @State private var repo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradFormRow(title: "Kind") {
                AinkradSelect(items: offeredSchemes, selection: $scheme) { $0.rawValue }
            }
            AinkradFormRow(title: "Identifier") {
                AinkradTextField(text: $identifier, placeholder: "Path, URL, branch name…")
            }
            AinkradFormRow(title: "Label") {
                AinkradTextField(text: $label, placeholder: "Label")
            }
            // A LATER sibling of the Kind row, never a wrapper around it: the
            // select that drives `scheme` must keep its structural identity
            // across this branch swap, or choosing `.branch` would unmount the
            // select in the very update its floating panel is closing.
            if repoScopedSchemes.contains(scheme) {
                AinkradFormRow(title: "Repo") {
                    AinkradTextField(text: $repo, placeholder: "Repo")
                }
            }
            AinkradButton(title: "Add link", style: .secondary, action: add)
        }
        .onSubmit(add)
    }

    private func add() {
        switch LinkValidation.normalize(
            scheme: scheme, identifier: identifier,
            label: label, repo: repo)
        {
        case .invalid(let message):
            report(message, .danger)
        case .valid(let link):
            do {
                try store.addLink(to: target, link: link, actor: .user)
                identifier = ""
                label = ""
                repo = ""
            } catch {
                report(error.localizedDescription, .danger)
            }
        }
    }
}

/// Renders a target's links with a remove control. Used by Overview (project
/// links) and ItemEditor (item links) so the two cannot drift.
struct LinkListView: View {
    @Bindable var store: ProjectStore
    let target: LinkTarget
    let links: [Link]
    /// Same contract as `LinkEditor.report` — no per-view error string.
    let report: (String, AinkradStatus) -> Void
    var opener: any LinkOpener = WorkspaceLinkOpener()

    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            ForEach(links) { link in
                let inert = isInert(link)
                HStack(spacing: AinkradSpacing.xs) {
                    Button {
                        open(link)
                    } label: {
                        HStack(spacing: AinkradSpacing.xs) {
                            AinkradIconGlyph(systemName: LinkSymbol.name(for: link.scheme))
                            Text(link.label)
                            if let repo = link.repo {
                                Text(repo).font(.caption)
                                    .foregroundStyle(theme.foreground.opacity(0.6))
                            }
                        }
                        .foregroundStyle(
                            inert
                                ? theme.foreground.opacity(0.5)
                                : theme.foreground)
                    }
                    .buttonStyle(.plain)
                    // Both label and identifier are agent-writable, and the row
                    // only shows the label — so without this the destination of
                    // a clickable row is unobservable before clicking.
                    .help(link.identifier)
                    // `.help` is mouse-only, and the identifier is the sole
                    // mitigation cited for accepting loopback and userinfo
                    // URLs — so VoiceOver must announce it too, not just a
                    // pointer hover.
                    .accessibilityLabel("\(link.scheme.rawValue) link: \(link.identifier)")
                    Spacer()
                    AinkradIconButton(systemName: "minus.circle") { remove(link) }
                        .help("Remove link")
                        .accessibilityLabel("Remove link")
                }
            }
        }
        .foregroundStyle(theme.foreground)
    }

    private func isInert(_ link: Link) -> Bool {
        if case .inert = LinkResolution.route(for: link) { return true }
        return false
    }

    private func open(_ link: Link) {
        do {
            // A nil reason means it was actioned; a reason means there was
            // nothing to do, and the user should be told which. Success stays
            // silent, exactly as the cleared error string used to be.
            if let reason = try LinkOpening.open(link, using: opener) {
                report(reason, .warning)
            }
        } catch let failure as LinkOpenError {
            report(failure.message, .danger)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }

    private func remove(_ link: Link) {
        do {
            // No bookmark to clean up: attachments store a path, not a
            // security-scoped bookmark (see `FolderAttachment`). That is what
            // makes every removal path — here, `remove_link` over MCP, project
            // delete — leak-free by construction rather than by remembering.
            try store.removeLink(from: target, link: link, actor: .user)
        } catch {
            report(error.localizedDescription, .danger)
        }
    }
}

/// The SF Symbol for a link kind, shared so Overview and ItemEditor agree.
enum LinkSymbol {
    static func name(for scheme: LinkScheme) -> String {
        switch scheme {
        case .repo: "shippingbox"
        case .branch: "arrow.triangle.branch"
        case .pr: "arrow.triangle.pull"
        case .commit: "circle.dotted"
        case .folder: "folder"
        case .file: "doc"
        case .url: "link"
        case .unknown: "questionmark"
        }
    }
}
