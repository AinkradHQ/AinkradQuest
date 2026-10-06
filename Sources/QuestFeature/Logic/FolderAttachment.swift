import Foundation

/// The one place a folder actually becomes a `Link`, shared by the
/// suggestion sheet and the persistent Overview picker so the two cannot
/// drift on validation. Builds the link through `LinkValidation.normalize` —
/// never hand-constructed. Returns a failure message, or `nil` on success;
/// never `try?`.
///
/// Deliberately saves NO per-attachment bookmark. An attachment is a recorded
/// path, not an open capability: nothing in Quest resolves an attached folder
/// today, and the cross-app resolution spike
/// (workspace `Docs/Audits/2026-07-30-cross-app-resolution.md`) shows the resolver that
/// would need scoped access does not exist and is not next. Writing a bookmark
/// blob per attachment that nothing ever reads is pure leak — every removal
/// path (UI, `remove_link` over MCP, project delete) would have to remember to
/// clear it, and the store exposes no key enumeration to sweep up the ones that
/// were missed. When a resolver does arrive it can mint bookmarks then, from a
/// real user selection, which is also the only way `.withSecurityScope` data is
/// legitimately obtained. The two ROOT grants remain the only bookmarks Quest
/// stores.
@MainActor
enum FolderAttachment {
    static func attach(
        url: URL, scheme: LinkScheme, to projectID: UUID,
        store: ProjectStore
    ) -> String? {
        switch LinkValidation.normalize(
            scheme: scheme, identifier: url.path,
            label: url.lastPathComponent, repo: nil)
        {
        case .invalid(let message):
            return message
        case .valid(let link):
            do {
                try store.addLink(to: .project(projectID), link: link, actor: .user)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
}
