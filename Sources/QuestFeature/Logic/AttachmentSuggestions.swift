import AinkradAppKit
import Foundation

/// A folder found under a granted root whose name matches the new project's
/// name. Never authoritative — the sheet that shows these starts every
/// checkbox unchecked, because a wrong suggestion silently accepted is worse
/// than no suggestion at all.
struct AttachmentSuggestion: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let scheme: LinkScheme
    var label: String { url.lastPathComponent }
}

enum AttachmentSuggestions {
    /// How a root's matches are classified: the projects root can yield either
    /// a repo or a plain folder, the vault root is always folders.
    enum RootKind {
        case projects
        case vault
    }

    /// Matches under ONE root. Must be called with that root's security scope
    /// held (see `FolderBookmark.withAccess`) — it reads the directory.
    static func candidates(
        projectName: String, root: URL,
        kind: RootKind
    ) -> [AttachmentSuggestion] {
        FolderMatch.candidates(for: projectName, in: root).map { url in
            switch kind {
            case .projects: AttachmentSuggestion(url: url, scheme: FolderMatch.linkKind(for: url))
            case .vault: AttachmentSuggestion(url: url, scheme: .folder)
            }
        }
    }

    /// Suggestions for a newly created project. Empty when no root is granted —
    /// that is the normal state, not an error. The per-folder picker
    /// (`FolderAttachButton`, on Overview) does not depend on this and is
    /// reachable regardless of whether any suggestion ever fired.
    static func build(
        projectName: String, projectsRoot: URL?,
        vaultRoot: URL?
    ) -> [AttachmentSuggestion] {
        var found: [AttachmentSuggestion] = []
        if let projectsRoot {
            found += candidates(projectName: projectName, root: projectsRoot, kind: .projects)
        }
        if let vaultRoot {
            found += candidates(projectName: projectName, root: vaultRoot, kind: .vault)
        }
        return found
    }

    /// The production entry point. Each root is scanned inside its OWN
    /// balanced access scope, so no scoped resource outlives the scan that
    /// needed it. The resulting `AttachmentSuggestion` URLs carry no access —
    /// they only ever become a `Link`'s path string (`FolderAttachment`), which
    /// touches no filesystem.
    static func build(
        projectName: String,
        in documents: PluginDocumentStore
    ) -> [AttachmentSuggestion] {
        var found: [AttachmentSuggestion] = []
        found +=
            FolderBookmark.withAccess(
                forKey: FolderBookmark.projectsRootKey,
                in: documents
            ) { root in
                candidates(projectName: projectName, root: root, kind: .projects)
            } ?? []
        found +=
            FolderBookmark.withAccess(
                forKey: FolderBookmark.vaultRootKey,
                in: documents
            ) { root in
                candidates(projectName: projectName, root: root, kind: .vault)
            } ?? []
        return found
    }
}
