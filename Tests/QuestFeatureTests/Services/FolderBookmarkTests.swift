import Foundation
import Testing

@testable import QuestFeature

@Suite("FolderBookmark")
struct FolderBookmarkTests {
    @Test("a saved bookmark resolves back to the same folder")
    func roundTrip() throws {
        let documents = MemoryDocumentStore()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-bm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // `bookmarkData(options: .withSecurityScope, ...)` can require a URL
        // that came from an actual user selection (NSOpenPanel) inside a
        // sandboxed app. This test environment is an unsandboxed CLI test
        // run against a plain temp directory, so the call may legitimately
        // fail here even though the identical production code path works
        // correctly inside the sandboxed host app. Skip loudly rather than
        // asserting a false negative, and do NOT drop `.withSecurityScope`
        // from production code to force this green.
        do {
            try FolderBookmark.save(folder, forKey: FolderBookmark.projectsRootKey, in: documents)
        } catch {
            withKnownIssue(
                """
                Cannot exercise real security-scoped bookmarks in this test \
                environment: bookmarkData(options: .withSecurityScope) failed \
                for a plain temp directory (\(error)). This is expected outside \
                a sandboxed host with a user-selected URL; production code is \
                unchanged.
                """
            ) {
                throw error
            }
            return
        }

        let resolved = FolderBookmark.withAccess(
            forKey: FolderBookmark.projectsRootKey,
            in: documents
        ) { $0 }

        #expect(resolved?.standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    @Test("no bookmark means withAccess skips the body and returns nil rather than failing")
    func absent() {
        var ran = false
        let result = FolderBookmark.withAccess(
            forKey: FolderBookmark.vaultRootKey,
            in: MemoryDocumentStore()
        ) { _ -> Int in
            ran = true
            return 1
        }
        #expect(result == nil)
        #expect(ran == false)
    }

    @Test("unresolvable bookmark data does not run the body and does not throw")
    func garbageBookmark() {
        let documents = MemoryDocumentStore()
        documents.setData(Data("not a bookmark".utf8), forKey: FolderBookmark.vaultRootKey)

        var ran = false
        let result = FolderBookmark.withAccess(
            forKey: FolderBookmark.vaultRootKey,
            in: documents
        ) { _ -> Int in
            ran = true
            return 1
        }
        #expect(result == nil)
        #expect(ran == false)
    }

    @Test("the two roots use distinct keys")
    func distinctKeys() {
        #expect(FolderBookmark.projectsRootKey != FolderBookmark.vaultRootKey)
        #expect(
            FolderBookmark.displayPathKey(forKey: FolderBookmark.projectsRootKey)
                != FolderBookmark.displayPathKey(forKey: FolderBookmark.vaultRootKey))
        // A display path must never collide with a bookmark blob's own key.
        #expect(
            FolderBookmark.displayPathKey(forKey: FolderBookmark.projectsRootKey)
                != FolderBookmark.projectsRootKey)
    }

    // MARK: - Balanced access (blockers 1 + 2)
    //
    // What these prove: `withAccess` runs its closure exactly once with the
    // resolved URL, and RELEASES access on every exit — normal return and
    // thrown error alike — because the stop sits in a `defer`. What they do NOT
    // prove: that a real sandbox's scoped-resource accounting returns to zero.
    // This test host is UNSANDBOXED, so
    // `startAccessingSecurityScopedResource()` typically returns `false` for a
    // URL that did not come from an NSOpenPanel selection, and there is no API
    // to read the retain count. The balance property is therefore verified
    // through the closure's observable lifetime and repeated reuse, not by
    // counting acquisitions.

    /// A folder plus a saved bookmark for it, or `nil` when this environment
    /// cannot mint security-scoped bookmark data at all (see `roundTrip()`).
    private func makeBookmarkedFolder(
        key: String,
        in documents: MemoryDocumentStore
    ) throws -> URL? {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try FolderBookmark.save(folder, forKey: key, in: documents)
        } catch {
            withKnownIssue("Cannot exercise real security-scoped bookmarks here (\(error)); see roundTrip().") {
                throw error
            }
            return nil
        }
        return folder
    }

    @Test("withAccess runs the body once, with the bookmarked folder, and returns its value")
    func withAccessRunsBody() throws {
        let documents = MemoryDocumentStore()
        guard
            let folder = try makeBookmarkedFolder(
                key: FolderBookmark.projectsRootKey,
                in: documents)
        else { return }
        defer { try? FileManager.default.removeItem(at: folder) }

        var calls = 0
        let result = FolderBookmark.withAccess(
            forKey: FolderBookmark.projectsRootKey,
            in: documents
        ) { url -> String in
            calls += 1
            return url.standardizedFileURL.path
        }

        #expect(calls == 1)
        #expect(result == folder.standardizedFileURL.path)
    }

    struct BodyFailure: Error {}

    @Test("a throwing body propagates, and the folder stays usable afterwards")
    func withAccessReleasesOnThrow() throws {
        let documents = MemoryDocumentStore()
        guard
            let folder = try makeBookmarkedFolder(
                key: FolderBookmark.projectsRootKey,
                in: documents)
        else { return }
        defer { try? FileManager.default.removeItem(at: folder) }

        // The error comes back out — nothing is swallowed...
        #expect(throws: BodyFailure.self) {
            _ = try FolderBookmark.withAccess(
                forKey: FolderBookmark.projectsRootKey,
                in: documents
            ) { _ -> Int in
                throw BodyFailure()
            }
        }

        // ...and access released by the `defer` on that failed call leaves the
        // grant usable. An unbalanced acquisition is what eventually breaks
        // this under a sandbox; balanced reuse never does.
        for _ in 0..<50 {
            let path = FolderBookmark.withAccess(
                forKey: FolderBookmark.projectsRootKey,
                in: documents
            ) { $0.standardizedFileURL.path }
            #expect(path == folder.standardizedFileURL.path)
        }
    }

    // MARK: - Grant display (minors 6 + 7)

    @Test("no bookmark reads as notGranted")
    func grantNotSet() {
        #expect(
            FolderBookmark.grant(
                forKey: FolderBookmark.vaultRootKey,
                in: MemoryDocumentStore()) == .notGranted)
    }

    @Test("a bookmark that no longer resolves reads as unresolvable, not notGranted")
    func grantUnresolvable() {
        let documents = MemoryDocumentStore()
        documents.setData(Data("not a bookmark".utf8), forKey: FolderBookmark.vaultRootKey)
        documents.setData(
            Data("/somewhere/gone".utf8),
            forKey: FolderBookmark.displayPathKey(forKey: FolderBookmark.vaultRootKey))

        // Distinct from `.notGranted`: that distinction is what gives the user
        // an explanation and a reachable Clear button for a broken grant.
        #expect(
            FolderBookmark.grant(forKey: FolderBookmark.vaultRootKey, in: documents)
                == .unresolvable(path: "/somewhere/gone"))
    }

    @Test("an unresolvable grant with no saved path still reports unresolvable")
    func grantUnresolvableWithoutPath() {
        let documents = MemoryDocumentStore()
        documents.setData(Data("not a bookmark".utf8), forKey: FolderBookmark.vaultRootKey)

        #expect(
            FolderBookmark.grant(forKey: FolderBookmark.vaultRootKey, in: documents)
                == .unresolvable(path: nil))
    }

    @Test("clearing a grant removes the bookmark and the saved display path")
    func clearRemovesDisplayPath() {
        let documents = MemoryDocumentStore()
        documents.setData(Data("x".utf8), forKey: FolderBookmark.vaultRootKey)
        documents.setData(
            Data("/p".utf8),
            forKey: FolderBookmark.displayPathKey(forKey: FolderBookmark.vaultRootKey))

        FolderBookmark.clear(forKey: FolderBookmark.vaultRootKey, in: documents)

        #expect(documents.keys.isEmpty)
        #expect(
            FolderBookmark.grant(
                forKey: FolderBookmark.vaultRootKey,
                in: documents) == .notGranted)
    }

    @Test("saving a grant records a display path, so settings can render without acquiring access")
    func saveRecordsDisplayPath() throws {
        let documents = MemoryDocumentStore()
        guard
            let folder = try makeBookmarkedFolder(
                key: FolderBookmark.vaultRootKey,
                in: documents)
        else { return }
        defer { try? FileManager.default.removeItem(at: folder) }

        let stored = documents.data(
            forKey: FolderBookmark.displayPathKey(forKey: FolderBookmark.vaultRootKey))
        #expect(stored.map { String(decoding: $0, as: UTF8.self) } == folder.path)

        // Resolvable right now, so it must read as granted rather than
        // unresolvable — and getting here acquired no scoped resource.
        if case .granted(let path) = FolderBookmark.grant(
            forKey: FolderBookmark.vaultRootKey,
            in: documents)
        {
            #expect(path.hasSuffix(folder.lastPathComponent))
        } else {
            Issue.record("a freshly saved, still-present folder must read as .granted")
        }
    }
}
