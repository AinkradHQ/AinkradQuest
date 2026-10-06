import Foundation
import Testing

@testable import QuestFeature

@Suite("AttachmentSuggestions")
struct AttachmentSuggestionTests {
    private func makeRoot(_ names: [String], gitIn: [String] = []) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quest-sugg-\(UUID().uuidString)")
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

    @Test("a matching repo under the projects root is suggested as a repo link")
    func repoSuggestion() throws {
        let projects = try makeRoot(["Optimus"], gitIn: ["Optimus"])
        let found = AttachmentSuggestions.build(
            projectName: "Optimus",
            projectsRoot: projects, vaultRoot: nil)
        #expect(found.map(\.scheme) == [.repo])
        #expect(found.first?.label == "Optimus")
    }

    @Test("a matching vault folder is suggested as a folder link")
    func vaultSuggestion() throws {
        let vault = try makeRoot(["Optimus"])
        let found = AttachmentSuggestions.build(
            projectName: "Optimus",
            projectsRoot: nil, vaultRoot: vault)
        #expect(found.map(\.scheme) == [.folder])
    }

    @Test("with no roots granted there are no suggestions, and that is not an error")
    func noRoots() {
        #expect(
            AttachmentSuggestions.build(
                projectName: "Optimus",
                projectsRoot: nil, vaultRoot: nil
            ).isEmpty)
    }

    @Test("both roots contribute, projects first")
    func bothRoots() throws {
        let projects = try makeRoot(["Quest"], gitIn: ["Quest"])
        let vault = try makeRoot(["Quest"])
        let found = AttachmentSuggestions.build(
            projectName: "Quest",
            projectsRoot: projects, vaultRoot: vault)
        #expect(found.count == 2)
        #expect(found.first?.scheme == .repo)
    }
}
