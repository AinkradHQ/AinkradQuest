import Foundation

/// The writes API minor 9 brought to Quest: the owner's sprint commit, labels, capacity and project settings.
extension QuestServerStore {
    /// "Commit sprint →": the app's commit is the owner's approval, so the sprint starts at once. Over the team's
    /// capacity the server asks for a reason (`overrideReason`).
    func commit(_ sprint: ServerSprint, overrideReason: String?, project: Int64) async {
        guard let server else { return }
        if let refused = await server.commit(sprint: sprint.id, overrideReason: overrideReason) {
            return refuse("Couldn't commit \(sprint.name)", refused)
        }
        if let company = company?.id { approvals = await server.approvals(company: company) ?? approvals }
        await refresh(project)
    }

    func createLabel(_ name: String, project: Int64) async {
        guard let server else { return }
        if let refused = await server.createLabel(project: project, name: name) {
            return refuse("Couldn't add the label", refused)
        }
        await refresh(project)
    }

    func renameLabel(_ label: ServerLabel, to name: String, project: Int64) async {
        guard let server else { return }
        if let refused = await server.renameLabel(project: project, label: label.id, name: name) {
            return refuse("Couldn't rename \(label.name)", refused)
        }
        await refresh(project)
    }

    func deleteLabel(_ label: ServerLabel, project: Int64) async {
        guard let server else { return }
        if let refused = await server.deleteLabel(project: project, label: label.id) {
            return refuse("Couldn't delete \(label.name)", refused)
        }
        await refresh(project)
    }

    /// Puts the label on the issue when it is off, takes it off when it is on.
    func toggle(_ label: ServerLabel, on issue: ServerIssue, project: Int64) async {
        guard let server else { return }
        let on = !issue.labels.contains { $0.id == label.id }
        if let refused = await server.setLabel(issue: issue.id, label: label.id, on: on) {
            return refuse("Couldn't label \(issue.key)", refused)
        }
        await refresh(project)
    }

    func setCapacity(_ capacity: Int?, agent: Int64, project: Int64) async {
        guard let server else { return }
        if let refused = await server.setCapacity(project: project, agent: agent, capacity: capacity) {
            return refuse("Couldn't set the capacity", refused)
        }
        await refresh(project)
    }

    /// A new project in the selected company, selected once the server made it. `false` when refused.
    func createProject(name: String, key: String, kanban: Bool, ownerApproves: Bool) async -> Bool {
        guard let server, let company = company?.id else { return false }
        if let refused = await server.createProject(
            company: company, name: name, key: key, kanban: kanban, ownerApproves: ownerApproves)
        {
            refuse("Couldn't create \(name)", refused)
            return false
        }
        projects = await server.projects(company: company) ?? projects
        if let made = companyProjects.first(where: { $0.key == key }) {
            await refresh(made.id)
            select(project: made.id)
        }
        return true
    }

    func updateProject(_ project: ServerProject, name: String, kanban: Bool, ownerApproves: Bool) async {
        guard let server else { return }
        if let refused = await server.updateProject(
            project.id, name: name, kanban: kanban, ownerApproves: ownerApproves)
        {
            return refuse("Couldn't save \(project.name)", refused)
        }
        if let company = company?.id { projects = await server.projects(company: company) ?? projects }
        await refresh(project.id)
    }

    func flow(of issue: ServerIssue) async -> IssueFlowInfo? { await server?.flow(issue: issue.id) }
}
