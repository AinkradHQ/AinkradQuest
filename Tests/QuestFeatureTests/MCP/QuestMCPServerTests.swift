import AinkradAppKit
import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("QuestMCPServer")
struct QuestMCPServerTests {
    @Test("the table publishes every operation the assistant needs")
    func toolNames() {
        #expect(
            Set(QuestMCPServer.tools.map(\.name))
                == Set([
                    "list_projects", "get_project", "search_items", "get_item",
                    "create_project", "update_project", "create_item", "update_item",
                    "move_item", "set_status", "delete_item", "delete_project",
                    "add_link", "remove_link", "update_status_scheme",
                ]))
    }

    /// Every tool's `operation` must be one of the tokens
    /// `QuestMCPOperations.run(operation:arguments:)` actually switches on —
    /// exactly `listProjects`, `getProject`, `searchItems`, `getItem`,
    /// `createProject`, `updateProject`, `createItem`, `updateItem`,
    /// `moveItem`, `setStatus`, `deleteItem`, `deleteProject`. A typo here
    /// would compile fine and produce a tool that always fails at runtime, so
    /// pin the whole mapping rather than trusting the routing test alone.
    @Test("every tool's operation token matches the operations layer exactly")
    func operationTokensMatchOperationsLayer() {
        let expected: [String: String] = [
            "list_projects": "listProjects",
            "get_project": "getProject",
            "search_items": "searchItems",
            "get_item": "getItem",
            "create_project": "createProject",
            "update_project": "updateProject",
            "create_item": "createItem",
            "update_item": "updateItem",
            "move_item": "moveItem",
            "set_status": "setStatus",
            "delete_item": "deleteItem",
            "delete_project": "deleteProject",
            "add_link": "addLink",
            "remove_link": "removeLink",
            "update_status_scheme": "updateStatusScheme",
        ]
        for tool in QuestMCPServer.tools {
            #expect(tool.operation == expected[tool.name])
        }
    }

    @Test("the new link tools are mutating but not destructive")
    func linkToolClassification() throws {
        for name in ["add_link", "remove_link"] {
            let tool = try #require(QuestMCPServer.tools.first { $0.name == name })
            #expect(!tool.destructive)
            #expect(!tool.readOnly)
        }
    }

    @Test("reads are readOnly and never destructive")
    func readClassification() {
        let reads = ["list_projects", "get_project", "search_items", "get_item"]
        for tool in QuestMCPServer.tools where reads.contains(tool.name) {
            #expect(tool.readOnly)
            #expect(!tool.destructive)
        }
    }

    @Test("only the deletes and the scheme rewrite are destructive — creates and updates are not")
    func destructiveClassification() {
        let destructive = QuestMCPServer.tools.filter(\.destructive).map(\.name)
        #expect(Set(destructive) == Set(["delete_item", "delete_project", "update_status_scheme"]))
    }

    @Test("update_status_scheme is destructive")
    func schemeToolIsDestructive() throws {
        let tool = try #require(QuestMCPServer.tools.first { $0.name == "update_status_scheme" })
        #expect(tool.destructive)
        #expect(!tool.readOnly)
    }

    @Test("every tool carries a schema that parses as a JSON object")
    func schemas() throws {
        for tool in QuestMCPServer.tools {
            let data = try #require(tool.schemaJSON.data(using: .utf8))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(object?["type"] as? String == "object")
        }
    }

    @Test("make registers every tool without failures")
    func make() {
        let (_, failures) = QuestMCPServer.make(appID: "quest") { _, _ in
            AgentActionResult(text: "", isError: false)
        }
        #expect(failures.isEmpty)
    }

    @Test("a call routes its tool's operation to the perform closure")
    func routing() async throws {
        var seen: String?
        let tool = try #require(QuestMCPServer.tools.first { $0.name == "create_item" })
        _ = await QuestMCPServer.invoke(tool, arguments: "{}") { operation, _ in
            seen = operation
            return AgentActionResult(text: "ok", isError: false)
        }
        #expect(seen == "createItem")
    }
}
