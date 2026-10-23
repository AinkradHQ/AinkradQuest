import AinkradAppKit
import Foundation

/// The writes behind Quest's server tabs. Each one goes to the server; the screen moves at once where it can
/// (a re-rank shows the new order) and the next snapshot — read when the event stream names the change — is the
/// truth. A refusal comes back in the server's words.
extension QuestServerStore {
    /// Drag to re-rank (backlog 01): shows the new order at once, asks the server, then reads the backlog again.
    /// When the server's order does not put the row where it was dropped — someone moved it or its anchor
    /// meanwhile — the server's order wins and a notice offers Undo.
    func rerank(_ move: RankMove, project: Int64) async {
        guard let server, let before = snapshots[project].map({ BacklogLogic.backlog($0.issues) }) else { return }
        pendingOrder[project] = BacklogLogic.applying(move, to: before)
        if let refused = await server.move(move) {
            pendingOrder[project] = nil
            return refuse("Couldn't move it", refused)
        }
        guard let fresh = await server.snapshot(project: project) else { return }
        snapshots[project] = fresh
        pendingOrder[project] = nil
        if BacklogLogic.conflicts(move, server: BacklogLogic.backlog(fresh.issues)) {
            let key = before.first { $0.id == move.issue }?.key ?? "It"
            notice = ServerNotice(
                message: "\(key) was moved on the server meanwhile — the server's order wins.", status: .warning,
                actionTitle: "Undo"
            ) { [weak self] in
                guard let self, let undo = BacklogLogic.undo(of: move.issue, before: before) else { return }
                notice = nil
                Task { await self.rerank(undo, project: project) }
            }
        }
    }

    /// A card dropped on a board column. A full column (WIP) refuses before the server is asked; any other
    /// refusal is the server's. Either way the card springs back.
    func drop(_ issue: ServerIssue, on column: ServerColumn, project: ServerProject) async {
        guard !column.states.contains(issue.state) else { return }
        let all = snapshots[project.id]?.issues ?? []
        if let full = BoardLogic.wipRefusal(moving: issue, into: column, of: all) {
            return bounce(issue, full, project: project, column: column)
        }
        switch BoardLogic.step(for: issue, to: column.state, reviewer: reviewer, me: me) {
        case .failure(let refusal):
            bounce(issue, refusal, project: project, column: column)
        case .success(let step):
            guard let server else { return }
            if let refused = await server.transition(issue: issue.id, step) {
                let wip = refused.status == 409 && refused.message.lowercased().contains("wip")
                return bounce(
                    issue, BoardRefusal(message: refused.message, fullColumn: wip ? column.title : nil),
                    project: project, column: column)
            }
            await refresh(project.id)
        }
    }

    private func bounce(_ issue: ServerIssue, _ refusal: BoardRefusal, project: ServerProject, column: ServerColumn) {
        bounced = issue.id
        Task {
            try? await Task.sleep(for: .seconds(1))
            if bounced == issue.id { bounced = nil }
        }
        notice = ServerNotice(message: refusal.message, status: .warning)
        guard refusal.fullColumn != nil else { return }
        notice?.actionTitle = "Raise limit…"
        notice?.action = { [weak self] in
            guard let self else { return }
            notice = nil
            Task { await self.raiseLimit(project: project, column: column) }
        }
    }

    /// "Raise limit…": one more card allowed in that column.
    func raiseLimit(project: ServerProject, column: ServerColumn) async {
        guard let server else { return }
        let current = snapshots[project.id]?.limits[column.state] ?? 0
        if let refused = await server.setLimit(project: project.id, state: column.state, limit: current + 1) {
            return refuse("Couldn't raise the limit", refused)
        }
        await refresh(project.id)
    }

    /// Into the planned sprint, or back to the backlog (sprint planning 02). Paused while the commit waits.
    func setSprint(_ issue: ServerIssue, to sprint: Int64?, project: Int64) async {
        guard let server else { return }
        if let refused = await server.setSprint(issue: issue.id, sprint: sprint) {
            return refuse(sprint == nil ? "Couldn't take \(issue.key) out" : "Couldn't add \(issue.key)", refused)
        }
        await refresh(project)
    }

    func estimate(_ issue: ServerIssue, points: Int?, project: Int64) async {
        guard let server else { return }
        if let refused = await server.estimate(issue: issue.id, points: points) {
            return refuse("Couldn't estimate \(issue.key)", refused)
        }
        await refresh(project)
    }

    /// Approve or reject the sprint commit — the same approval Citadel's inbox shows (decision #33).
    func decide(_ approval: ServerApproval, approve: Bool, reply: String?, project: Int64) async {
        guard let server else { return }
        if let refused = await server.decide(approval: approval.id, approve: approve, reply: reply) {
            return refuse(approve ? "Couldn't approve the sprint" : "Couldn't reject the sprint", refused)
        }
        if let company = company?.id { approvals = await server.approvals(company: company) ?? approvals }
        await refresh(project)
    }

    func createIssue(title: String, epic: Int64?, project: Int64) async {
        guard let server else { return }
        if let refused = await server.createIssue(project: project, title: title, epic: epic) {
            return refuse("Couldn't add the item", refused)
        }
        await refresh(project)
    }

    func refresh(_ project: Int64) async {
        guard let server, let fresh = await server.snapshot(project: project) else { return }
        snapshots[project] = fresh
    }

    private func refuse(_ title: String, _ answer: ServerAnswer) {
        let said = answer.message.isEmpty ? "the server answered \(answer.status)" : answer.message
        notice = ServerNotice(
            message: answer.status == 0 ? "\(title): the server did not answer." : "\(title): \(said)",
            status: .danger)
    }
}
