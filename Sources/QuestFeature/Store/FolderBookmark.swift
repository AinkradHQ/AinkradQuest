import AinkradAppKit
import Foundation

/// Security-scoped folder bookmarks for Quest's two root grants, stored in the
/// app's own document store.
///
/// The host's entitlements carry no `app-sandbox` key today, so a plain path
/// string would in fact work right now. This follows Lore's proven pattern
/// (`VaultBookmark`) anyway, for forward-compatibility: the mechanism is
/// correct whether or not the process is sandboxed, and it is the only shape
/// that keeps working if the host ever adopts the sandbox. Nothing here
/// depends on being unsandboxed, and `.withSecurityScope` is never weakened to
/// make a test pass.
///
/// Access is acquired ONLY inside `withAccess`, which balances every
/// `startAccessingSecurityScopedResource()` with a `defer`red stop. There is
/// deliberately no API that hands out a resolved, access-started URL: an
/// unbalanced acquisition exhausts the process's scoped-resource limit under a
/// real sandbox, and Quest resolves from per-project-creation code, not once at
/// launch. Display code uses `grant(forKey:in:)`, which never acquires access.
enum FolderBookmark {
    static let projectsRootKey = "projectsRootBookmark"
    static let vaultRootKey = "vaultRootBookmark"

    /// Key holding the human-readable path of a granted root, saved alongside
    /// the bookmark. Settings renders from this, so showing the current grant
    /// never resolves a bookmark and never acquires a scoped resource.
    static func displayPathKey(forKey key: String) -> String { "\(key)-displayPath" }

    /// What settings needs to render, with "never granted" and "granted but no
    /// longer resolvable" kept distinct — a moved or deleted root must not
    /// masquerade as "Not set", because the user would have no way to
    /// understand why suggestions stopped and no reason to clear it.
    enum Grant: Equatable {
        case notGranted
        /// Resolvable right now. `path` is the freshly resolved location, which
        /// can differ from the saved display path if the folder was moved.
        case granted(path: String)
        /// A bookmark exists but no longer resolves. `path` is the last known
        /// location, for the message; it is not usable for access.
        case unresolvable(path: String?)
    }

    static func save(_ url: URL, forKey key: String, in documents: PluginDocumentStore) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        documents.setData(data, forKey: key)
        documents.setData(Data(url.path.utf8), forKey: displayPathKey(forKey: key))
    }

    /// Read-only status for DISPLAY. Resolving a bookmark does not by itself
    /// acquire the scoped resource — only `startAccessingSecurityScopedResource`
    /// does, and this never calls it. Safe to call from a view body.
    static func grant(forKey key: String, in documents: PluginDocumentStore) -> Grant {
        guard let data = documents.data(forKey: key) else { return .notGranted }
        let lastKnown = savedPath(forKey: key, in: documents)
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &stale)
            return .granted(path: url.path)
        } catch {
            return .unresolvable(path: lastKnown)
        }
    }

    /// Runs `body` with access to the bookmarked folder held for exactly the
    /// duration of that call, and returns its result — or `nil` when no
    /// bookmark is stored or it no longer resolves.
    ///
    /// Everything that touches the filesystem under a granted root must happen
    /// inside this closure. That is what makes the suggestion path legitimate:
    /// a folder discovered by scanning is reachable because the parent root's
    /// grant is open for the scan, not because some earlier acquisition was
    /// never released.
    ///
    /// A stale-but-resolvable bookmark is re-saved here, so a moved or renamed
    /// root is repaired on first use instead of decaying silently.
    static func withAccess<T>(
        forKey key: String, in documents: PluginDocumentStore,
        _ body: (URL) throws -> T
    ) rethrows -> T? {
        guard let data = documents.data(forKey: key) else { return nil }
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            // A bookmark that no longer resolves is not an error the caller can
            // act on — it is the same "no root available" situation as no
            // bookmark at all. `grant(forKey:in:)` is what surfaces it to the
            // user, in settings, with a Clear button.
            return nil
        }

        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        if stale {
            // Best effort, and deliberately non-fatal: `url` is valid for THIS
            // call regardless, and access is already held. If re-saving fails
            // the old bookmark stays and we try again next time — there is no
            // caller to report it to, and failing the whole operation would
            // turn a self-healing refresh into an outage.
            do {
                try save(url, forKey: key, in: documents)
            } catch {
                assertionFailure("Could not refresh stale bookmark for \(key): \(error)")
            }
        }

        return try body(url)
    }

    static func clear(forKey key: String, in documents: PluginDocumentStore) {
        documents.setData(nil, forKey: key)
        documents.setData(nil, forKey: displayPathKey(forKey: key))
    }

    private static func savedPath(
        forKey key: String,
        in documents: PluginDocumentStore
    ) -> String? {
        guard let data = documents.data(forKey: displayPathKey(forKey: key)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
