import AinkradAppKit
import Foundation
import Testing

@testable import QuestFeature

@MainActor
@Suite("Quest's notification vocabulary")
struct QuestSignalReporterTests {
    private final class RecordingEmitter: PluginSignalEmitter {
        struct Call {
            let kind: String
            let severity: SignalSeverity
            let title: String
            let body: String?
            let importance: SignalImportance
            let deepLink: SignalDeepLink?
            let dedupeKey: String?
        }
        var calls: [Call] = []

        func emit(
            kind: String, severity: SignalSeverity, title: String, body: String?,
            importance: SignalImportance, deepLink: SignalDeepLink?,
            actions: [SignalAction], dedupeKey: String?
        ) {
            calls.append(
                Call(
                    kind: kind, severity: severity, title: title, body: body,
                    importance: importance, deepLink: deepLink, dedupeKey: dedupeKey))
        }
        func own(limit: Int) -> [SignalEvent] { [] }
        func handleAction(
            _ actionID: String,
            _ handler: @escaping @MainActor () async -> Void
        ) -> AgentActionToken {
            AgentActionToken()
        }
        func removeActionHandler(_ token: AgentActionToken) {}
    }

    private func reporter() -> (QuestSignalReporter, RecordingEmitter) {
        let emitter = RecordingEmitter()
        return (QuestSignalReporter(signals: emitter), emitter)
    }

    @Test("agent-filed work is reported once per project, with a count")
    func agentWork() {
        let (reporter, emitter) = self.reporter()
        let project = UUID()
        reporter.agentFiledWork(
            projectName: "Ainkrad", projectID: project,
            summary: "Created 4 tasks under Signal M3", count: 4)
        #expect(emitter.calls.count == 1)
        #expect(emitter.calls[0].kind == "work.filed-by-agent")
        #expect(emitter.calls[0].severity == .info)
        #expect(emitter.calls[0].title == "Sage made 4 changes in Ainkrad")
        #expect(emitter.calls[0].importance == .normal, "work arriving is information")
        #expect(emitter.calls[0].dedupeKey == "quest.agent-work:\(project.uuidString)")
    }

    @Test("a single agent change reads as singular")
    func singleAgentChange() {
        let (reporter, emitter) = self.reporter()
        reporter.agentFiledWork(
            projectName: "Ainkrad", projectID: UUID(),
            summary: "Moved one item", count: 1)
        #expect(emitter.calls[0].title == "Sage updated Ainkrad")
    }

    @Test("an unreadable overlay is the urgent case, because the loss is silent")
    func unreadableIsUrgent() {
        // Writes are refused so corrupt bytes are not overwritten, which means
        // the user can keep editing and nothing is saved. They cannot discover
        // that by working.
        let (reporter, emitter) = self.reporter()
        reporter.overlayUnreadable(projectName: "Raven", projectID: UUID())
        #expect(emitter.calls[0].kind == "overlay.unreadable")
        #expect(emitter.calls[0].severity == .failure)
        #expect(emitter.calls[0].importance == .urgent)
        #expect(emitter.calls[0].body?.contains("not being saved") == true)
        #expect(
            emitter.calls[0].body?.contains("left") == true,
            "it must say the data on disk was not overwritten")
    }

    @Test("a retryable write failure is NOT reported like data loss")
    func writeFailedIsMilder() {
        // Putting a retryable failure beside genuine data loss teaches the user
        // that both mean the same thing.
        let (reporter, emitter) = self.reporter()
        reporter.overlayWriteFailed(reason: "The disk is full.")
        #expect(emitter.calls[0].severity == .warning)
        #expect(emitter.calls[0].importance == .normal)
        #expect(emitter.calls[0].body?.contains("retried") == true)
    }

    @Test("both project-scoped kinds deep-link to the project by locator")
    func deepLinksCarryTheProject() {
        // Generation 10: the locator is what lets the host focus the pane
        // showing THIS project rather than the first Quest pane.
        let (reporter, emitter) = self.reporter()
        let project = UUID()
        reporter.agentFiledWork(projectName: "P", projectID: project, summary: "s", count: 1)
        reporter.overlayUnreadable(projectName: "P", projectID: project)
        for call in emitter.calls {
            #expect(call.deepLink?.appID == "quest")
            #expect(call.deepLink?.locator == project.uuidString)
        }
    }

    @Test("every kind Quest emits is one the host will accept")
    func kindsAreValid() {
        let (reporter, emitter) = self.reporter()
        reporter.agentFiledWork(projectName: "P", projectID: UUID(), summary: "s", count: 2)
        reporter.overlayUnreadable(projectName: "P", projectID: UUID())
        reporter.overlayWriteFailed(reason: "x")
        #expect(emitter.calls.count == 3)
        for call in emitter.calls {
            #expect(SignalKind.isValid(call.kind), "\(call.kind) would be rejected at ingest")
        }
    }
}

@MainActor
@Suite("Which agent calls are worth a notification")
struct QuestAgentActivityRuleTests {
    @Test("reads are not news")
    func readsExcluded() {
        // list_projects returning forty projects is the assistant doing its
        // job, not something that happened to the user's work.
        for read in ["listProjects", "getProject", "searchItems", "getItem"] {
            #expect(
                !QuestAgentActivityReporter.mutatingOperations.contains(read),
                "\(read) must not be reported")
        }
    }

    @Test("every mutating MCP operation is covered")
    func mutationsCovered() {
        // The list is written out by hand, so it can fall behind the server's
        // tools. This is the tripwire: if a new mutating tool is added and not
        // listed, its changes arrive silently.
        for mutation in [
            "createProject", "updateProject", "deleteProject",
            "createItem", "updateItem", "moveItem", "setStatus",
            "deleteItem", "addLink", "removeLink", "updateStatusScheme",
        ] {
            #expect(
                QuestAgentActivityReporter.mutatingOperations.contains(mutation),
                "\(mutation) mutates and must be reported")
        }
    }

    @Test("the covered list matches the server's mutating tools exactly")
    func listMatchesServer() {
        // Derived from the server rather than restated, so a tool added there
        // fails here instead of silently never notifying. Reads are the
        // difference set, and are named explicitly so a NEW read also fails
        // this test and gets classified deliberately.
        let known: Set<String> = [
            "listProjects", "getProject", "searchItems", "getItem",
        ]
        let all = Set(QuestMCPServer.tools.map(\.operation))
        let unclassified =
            all
            .subtracting(QuestAgentActivityReporter.mutatingOperations)
            .subtracting(known)
        #expect(
            unclassified.isEmpty,
            "these MCP operations are neither reported nor knowingly excluded")
    }
}
