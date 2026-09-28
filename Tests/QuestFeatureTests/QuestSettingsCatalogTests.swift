import Testing
import Foundation
import AinkradAppKit
@testable import QuestFeature

@Suite("Quest — declared settings")
@MainActor
struct QuestSettingsCatalogTests {
    private func context() -> QuestSettingsCatalog.Context {
        let repository = InMemoryProjectRepository()
        let overlay = OverlayStore(repository: repository)
        let documents = MemoryDocumentStore()
        return .init(documents: documents,
                     store: ProjectStore(repository: repository, overlay: overlay),
                     registry: ConnectionRegistry(repository: repository, credentials: InMemoryCredentialStore()),
                     snapshots: SnapshotStore(overlay: overlay, documents: documents, projectIDs: { [] }),
                     state: QuestSettingsState())
    }

    @Test("three declared tabs, and not one custom row")
    func pageIsDeclared() {
        let page = QuestSettingsCatalog.page(context())
        #expect(page.groups.map(\.title) == ["Connections", "Backups", "Folders"])
        let customs = page.groups.flatMap(\.fields).filter { if case .custom = $0.kind { true } else { false } }
        #expect(customs.isEmpty)
    }

    @Test("the add form writes the draft, and Add registers the connection")
    func addFormAddsAConnection() throws {
        let c = context()
        func field(_ label: String) throws -> SettingsField {
            try #require(QuestSettingsCatalog.page(c).groups[0].fields.first { $0.label == label })
        }
        guard case .text(let name) = try field("Name").kind,
              case .text(let account) = try field("Account").kind,
              case .secure(let token) = try field("Token").kind else { Issue.record("wrong kinds"); return }
        name.wrappedValue = "Work"
        account.wrappedValue = "me@example.com"
        token.wrappedValue = "secret"
        guard case .action(_, let add) = try field("Add connection").kind else { Issue.record("no Add"); return }
        add()
        #expect(c.registry.connections.map(\.accountLabel) == ["Work"])
        #expect(c.state.draft.accountLabel.isEmpty, "the form did not reset after adding")
        // The new connection is listed as its own row.
        #expect(QuestSettingsCatalog.page(c).groups[0].fields.first?.label == "Work")
    }

    @Test("backups off by default says so, and has no Turn off row")
    func backupsOffByDefault() throws {
        let backups = QuestSettingsCatalog.page(context()).groups[1]
        let vault = try #require(backups.fields.first)
        #expect(vault.help?.hasPrefix("Not set — backups are off") == true)
        #expect(!backups.fields.contains { $0.label == "Turn off backups" })
    }
}
