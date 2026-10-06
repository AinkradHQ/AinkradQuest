import AinkradAppKit
import Foundation

/// Quest's notification vocabulary, in one place so the kinds stay consistent
/// and every emission decision is visible together.
///
/// **Read out of the code, not out of the name.** The plan for this adoption
/// suggested `session.completed` / `session.failed` / `session.needs-input`;
/// Quest has no sessions and nothing that waits for the user. What it does
/// have is an append-only activity log that already distinguishes assistant
/// changes from the user's own, and an overlay store that already models its
/// own health as a type.
@MainActor
public struct QuestSignalReporter {
    let signals: PluginSignalEmitter

    public init(signals: PluginSignalEmitter) { self.signals = signals }

    /// The assistant filed or changed work.
    ///
    /// **This is the kind worth having.** `ActivityEvent.actor` is already
    /// `.user` or `.agent`, so "something happened while you were not looking"
    /// is not something this adoption had to invent — it is recorded already.
    /// A user moving their own card needs no notification; the assistant
    /// filing four tasks into a project while the user was elsewhere is
    /// exactly what the feed is for.
    ///
    /// Deduped per project, so a batch of twelve agent-filed items is one row
    /// with a count rather than twelve rows nobody reads.
    func agentFiledWork(projectName: String, projectID: UUID, summary: String, count: Int) {
        signals.emit(
            kind: "work.filed-by-agent",
            severity: .info,
            title: count == 1
                ? "Sage updated \(projectName)"
                : "Sage made \(count) changes in \(projectName)",
            body: summary,
            // Never urgent, and never a toast worth stealing focus for: work
            // arriving is information, not a demand. The user reads it when
            // they next look at the feed.
            importance: .normal,
            deepLink: SignalDeepLink(
                appID: "quest",
                payload: Data(projectID.uuidString.utf8),
                locator: projectID.uuidString),
            dedupeKey: "quest.agent-work:\(projectID.uuidString)")
    }

    /// A project's overlay document exists but cannot be decoded.
    ///
    /// **The urgent one, and for a sharper reason than most failures: the
    /// consequence is SILENT.** Writes for an unreadable project are refused
    /// on purpose, so the corrupt bytes are not overwritten with empty state —
    /// which means the user can keep editing and nothing is being saved. They
    /// cannot discover that by working; something has to tell them.
    ///
    /// Deduped per project, since one project has one corrupt overlay however
    /// many times it is noticed.
    func overlayUnreadable(projectName: String, projectID: UUID) {
        signals.emit(
            kind: "overlay.unreadable",
            severity: .failure,
            title: "\(projectName) cannot be edited",
            body: "Quest could not read this project's saved layout, so changes "
                + "to it are not being saved. Its data on disk has been left "
                + "untouched rather than overwritten.",
            importance: .urgent,
            deepLink: SignalDeepLink(
                appID: "quest",
                payload: Data(projectID.uuidString.utf8),
                locator: projectID.uuidString),
            dedupeKey: "quest.overlay-unreadable:\(projectID.uuidString)")
    }

    /// An ordinary, retryable write failure.
    ///
    /// `.warning` rather than `.failure`, and never urgent: unlike the above,
    /// the change is still in memory and the next write can succeed. Reporting
    /// it as a failure would put it beside genuine data loss and teach the
    /// user that both mean the same thing.
    func overlayWriteFailed(reason: String) {
        signals.emit(
            kind: "overlay.write-failed",
            severity: .warning,
            title: "Quest could not save a layout change",
            body: reason + " The change is still open and will be retried.",
            importance: .normal,
            dedupeKey: "quest.overlay-write-failed")
    }
}
