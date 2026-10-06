import AinkradAppKit
import Foundation

/// Decides whether one agent tool call is worth a notification, and files it.
///
/// Separate from `QuestSignalReporter` because these are two different
/// questions: the reporter owns the vocabulary, this owns the editorial rule.
/// Keeping them apart is what lets the rule be tested without a store.
@MainActor
enum QuestAgentActivityReporter {
    /// Operations that CHANGE something. Reads are excluded by name rather
    /// than by inspecting the result, because a read that "succeeded" is still
    /// not news — `list_projects` returning forty projects is the assistant
    /// doing its job, not something that happened to the user's work.
    ///
    /// Listed explicitly rather than derived from a `destructive` flag: that
    /// flag is about whether the host should confirm, which is a different
    /// question from whether the user should be told afterwards.
    static let mutatingOperations: Set<String> = [
        "createProject", "updateProject", "deleteProject",
        "createItem", "updateItem", "moveItem", "setStatus", "deleteItem",
        "addLink", "removeLink", "updateStatusScheme",
    ]

    /// Files a notification when an agent mutation succeeded.
    ///
    /// A FAILED agent call is deliberately not reported here: the failure is
    /// returned to the assistant, which tells the user in the conversation
    /// they are already reading. A feed row would duplicate it — the same
    /// reasoning that kept Leyline out of Signal entirely.
    static func report(
        operation: String,
        result: AgentActionResult,
        store: ProjectStore,
        reporter: QuestSignalReporter
    ) {
        guard mutatingOperations.contains(operation), !result.isError else { return }

        // The most recent agent-authored activity is what this call produced.
        // Read back from the log rather than reconstructed from the arguments,
        // so the notification says what actually landed.
        let recent = store.projects
            .flatMap { project in
                store.activity(for: project.id)
                    .filter { $0.actor == .agent }
                    .map { (project, $0) }
            }
            .sorted { $0.1.at > $1.1.at }

        guard let (project, latest) = recent.first else { return }

        // How many agent changes this project has seen in the last minute —
        // the window a batch of tool calls arrives in. The host coalesces on
        // the dedupe key, so this count is what makes the single row say
        // "4 changes" instead of restating the last one.
        let window = Date().addingTimeInterval(-60)
        let count = store.activity(for: project.id)
            .filter { $0.actor == .agent && $0.at >= window }
            .count

        reporter.agentFiledWork(
            projectName: project.name,
            projectID: project.id,
            summary: latest.summary,
            count: max(count, 1))
    }
}
