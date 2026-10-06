import Foundation
import Testing

@testable import QuestFeature

@Suite("FolderMatch")
struct FolderMatchTests {
    private func makeTree(_ names: [String], gitIn: [String] = []) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-match-\(UUID().uuidString)")
        for name in names {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in gitIn {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name).appendingPathComponent(".git"),
                withIntermediateDirectories: true)
        }
        return root
    }

    @Test("a case-insensitive name match is offered")
    func matches() throws {
        let root = try makeTree(["Optimus", "Unrelated"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = FolderMatch.candidates(for: "optimus", in: root)
        #expect(found.map(\.lastPathComponent) == ["Optimus"])
    }

    @Test("no match yields nothing rather than a guess")
    func noMatch() throws {
        let root = try makeTree(["Something", "Else"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FolderMatch.candidates(for: "Quest", in: root).isEmpty)
    }

    @Test("several matches are all offered, so the user chooses")
    func severalMatches() throws {
        let root = try makeTree(["Quest", "quest-api"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FolderMatch.candidates(for: "quest", in: root).count == 2)
    }

    @Test("only one level is scanned")
    func oneLevelOnly() throws {
        let root = try makeTree(["outer/Quest"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FolderMatch.candidates(for: "Quest", in: root).isEmpty)
    }

    @Test("a directory containing .git is a repo link; otherwise a folder link")
    func linkKind() throws {
        let root = try makeTree(["WithGit", "Plain"], gitIn: ["WithGit"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FolderMatch.linkKind(for: root.appendingPathComponent("WithGit")) == .repo)
        #expect(FolderMatch.linkKind(for: root.appendingPathComponent("Plain")) == .folder)
    }

    @Test("a missing root yields nothing rather than throwing")
    func missingRoot() {
        let ghost = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(FolderMatch.candidates(for: "anything", in: ghost).isEmpty)
    }
}
