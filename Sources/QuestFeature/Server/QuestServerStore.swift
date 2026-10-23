import AinkradAppKit
import Foundation
import Observation
import QuestCitadelAPI

/// What Quest remembers about its Citadel server in `host.documents` — never the device key, which lives only in
/// `host.secrets` (`DeviceKeyStore`). Plugin secrets are per plugin, so Quest cannot read the Citadel plugin's
/// key: it connects on its own, with the same server address and a device key of its own.
struct ServerSettings: Codable, Equatable, Sendable {
    static let key = "citadel-server"
    var server: String?
    var companyID: Int64?
    var projectID: Int64?
    /// True once a connect has succeeded: from then on Quest is in server mode (decision #27) until Disconnect.
    var hasConnected = false
    /// The last event seq read, per `server|company`.
    var cursors: [String: Int64] = [:]
}

/// A company on the server, as the switcher shows it.
struct ServerCompany: Identifiable, Equatable, Sendable {
    let id: Int64
    var name: String
    var isClient: Bool
}

/// A standing message over the server surfaces — a refusal, or a conflict with Undo.
struct ServerNotice: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var status: AinkradStatus
    var actionTitle: String?
    var action: (@MainActor () -> Void)?

    static func == (a: ServerNotice, b: ServerNotice) -> Bool { a.id == b.id }
}

/// Quest in server mode: one Citadel server and company, its projects and their backlog / sprints / board, kept
/// current by the event stream — an event names what changed and only that is read again; nothing polls.
@MainActor
@Observable
final class QuestServerStore {
    enum Phase: Equatable {
        case setup
        case connecting(String)
        case connected
        /// 401: the key was revoked or never existed.
        case rejected
        case offline(String)
    }

    // The connect form.
    var serverDraft = ""
    var keyDraft = ""
    private(set) var formProblem: String?

    var phase: Phase = .setup
    private(set) var settings: ServerSettings
    var companies: [ServerCompany] = []
    var userID: Int64?
    var userName = "You"
    var projects: [ServerProject] = []
    var snapshots: [Int64: ProjectSnapshot] = [:]
    var agents: [ServerAgent] = []
    var approvals: [ServerApproval] = []
    var requirements: [ServerRequirement] = []
    var runs: [ServerRun] = []
    var streamStatus: EventStream.Status?
    var notice: ServerNotice?
    /// Issues an agent just changed: their rows flash their accent once.
    var flashing: Set<Int64> = []
    /// The card a refused drop sends back, outlined amber for a moment.
    var bounced: Int64?
    /// The backlog as the person last arranged it, shown until the server's answer lands.
    var pendingOrder: [Int64: [ServerIssue]] = [:]

    private let documents: PluginDocumentStore
    private let keys: DeviceKeyStore
    private let session: URLSession
    private let connector: EventSocketConnector
    @ObservationIgnored var server: CitadelServer?
    @ObservationIgnored private var stream: EventStream?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var pending: Set<Reload> = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date.distantPast

    enum Reload: Hashable { case projects, approvals, runs, agents, requirements }

    init(
        documents: PluginDocumentStore, secrets: PluginSecretStore, session: URLSession = CitadelServer.makeSession(),
        connector: EventSocketConnector? = nil
    ) {
        self.documents = documents
        self.keys = DeviceKeyStore(secrets: secrets)
        self.session = session
        self.connector = connector ?? URLSessionEventSocket.connector(session: session)
        self.settings =
            documents.data(forKey: ServerSettings.key).flatMap {
                try? JSONDecoder().decode(ServerSettings.self, from: $0)
            }
            ?? ServerSettings()
        self.serverDraft = settings.server ?? ""
    }

    // MARK: - Reading

    /// Server mode: a connect has succeeded and the person has not disconnected (decision #27).
    var isServerMode: Bool { settings.hasConnected && settings.server != nil }
    var host: String { (try? ServerAddress(settings.server ?? serverDraft))?.host ?? serverDraft }
    var company: ServerCompany? { companies.first { $0.id == settings.companyID } ?? companies.first }
    var companyProjects: [ServerProject] { projects.filter { $0.companyID == company?.id } }
    var selectedProject: ServerProject? { companyProjects.first { $0.id == settings.projectID } }
    var snapshot: ProjectSnapshot? { selectedProject.flatMap { snapshots[$0.id] } }
    var me: ServerActor { userID.map(ServerActor.human) ?? .human(1) }
    var hasStoredKey: Bool { (try? ServerAddress(settings.server ?? "")).flatMap(keys.key(for:)) != nil }

    func agent(_ id: Int64?) -> ServerAgent? { id.flatMap { id in agents.first { $0.id == id } } }
    func requirement(_ id: Int64?) -> ServerRequirement? { id.flatMap { id in requirements.first { $0.id == id } } }
    func run(on issue: ServerIssue) -> ServerRun? {
        runs.first { $0.issueID == issue.id && ["queued", "claimed", "running"].contains($0.state) }
    }

    /// The QA agent that reviews a card moved into In review (decision #16).
    var reviewer: ServerActor? {
        agents.first { $0.role.lowercased().contains("qa") && $0.status != "terminated" }.map { .agent($0.id) }
    }

    /// The name an actor goes by on a card.
    func name(_ actor: ServerActor) -> String? {
        switch actor {
        case .agent(let id): agent(id)?.name
        case .human: userName
        case .timer, .none: nil
        }
    }

    // MARK: - Connecting

    /// Reconnects with the saved server and key on window open.
    func start() {
        guard work == nil, stream == nil, isServerMode, hasStoredKey else { return }
        connect()
    }

    func connect() {
        stop()
        formProblem = nil
        let address: ServerAddress
        do {
            address = try ServerAddress(serverDraft.isEmpty ? (settings.server ?? "") : serverDraft)
        } catch {
            formProblem = ServerAddress.message(for: error)
            return
        }
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = typed.isEmpty ? keys.key(for: address) : typed else {
            formProblem = "Paste the device key."
            return
        }
        work = Task { await runConnect(address: address, key: key) }
    }

    /// Back to local Quest: forgets the key and leaves server mode. Local projects were never touched.
    func disconnect() {
        stop()
        if let address = try? ServerAddress(settings.server ?? "") { keys.setKey(nil, for: address) }
        update { $0.hasConnected = false }
        companies = []
        projects = []
        snapshots = [:]
        phase = .setup
    }

    func select(company id: Int64) {
        guard id != settings.companyID, let server else { return }
        saveCursor(force: true)
        update {
            $0.companyID = id
            $0.projectID = nil
        }
        snapshots = [:]
        stream?.stop()
        startStream(server.scoped(to: id))
        Task { await loadCompany() }
    }

    func select(project id: Int64?) { update { $0.projectID = id } }

    func stop() {
        work?.cancel()
        work = nil
        stream?.stop()
        stream = nil
        saveCursor(force: true)
    }

    func retryNow() { stream?.retryNow() }

    private func runConnect(address: ServerAddress, key: String) async {
        phase = .connecting("Checking key")
        let base = CitadelServer(address: address, deviceKey: key, company: nil, session: session)
        do {
            let me = try await base.me()
            guard !Task.isCancelled else { return }
            keys.setKey(key, for: address)
            keyDraft = ""
            userID = me.userID
            userName = me.userName
            companies = me.companies.map { ServerCompany(id: $0.id, name: $0.name, isClient: $0.kind.word == "client") }
            let saved = settings.companyID
            let companyID = companies.contains { $0.id == saved } ? saved : companies.first?.id
            update {
                $0.server = address.origin.absoluteString
                $0.companyID = companyID
            }
            serverDraft = address.origin.absoluteString
            phase = .connecting("Loading projects")
            startStream(base.scoped(to: settings.companyID))
            await loadCompany()
            guard !Task.isCancelled else { return }
            phase = .connected
            update { $0.hasConnected = true }
        } catch .rejected {
            phase = .rejected
        } catch {
            phase = .offline(EventStream.describe(error))
        }
        work = nil
    }

    private func startStream(_ server: CitadelServer) {
        self.server = server
        let stream = EventStream(
            server: server, cursor: cursor, connect: connector,
            onStatus: { [weak self] in self?.streamStatus = $0 },
            onEvent: { [weak self] in self?.received($0) },
            onCursor: { [weak self] _ in self?.saveCursor(force: false) })
        self.stream = stream
        stream.start()
    }

    // MARK: - Loading

    /// The company's projects, agents, approvals, requirements and live runs, then every project's snapshot.
    func loadCompany() async {
        guard let server, let company = company?.id else { return }
        async let projects = server.projects(company: company)
        async let agents = server.agents(company: company)
        async let approvals = server.approvals(company: company)
        async let requirements = server.requirements()
        async let runs = server.liveRuns(company: company)
        self.projects = await projects ?? self.projects
        self.agents = await agents ?? self.agents
        self.approvals = await approvals ?? self.approvals
        self.requirements = await requirements ?? self.requirements
        self.runs = await runs ?? self.runs
        if selectedProject == nil { update { $0.projectID = companyProjects.first?.id } }
        await reloadProjects()
    }

    /// Every project of the company: Today reads across them.
    // ponytail: re-reads all of the company's projects on an issue event; scope by the event's project when the
    // audit details carry one.
    func reloadProjects() async {
        guard let server else { return }
        for project in companyProjects {
            if let snapshot = await server.snapshot(project: project.id) { snapshots[project.id] = snapshot }
        }
        pendingOrder = [:]
    }

    // MARK: - The event stream

    func received(_ event: Schemas.Event) {
        guard case .audit(let audit) = event.payload else { return }
        let area = audit.action.split(separator: ".").first.map(String.init) ?? ""
        switch area {
        case "issue", "sprint", "epic", "wip", "project", "comment": pending.insert(.projects)
        case "approval":
            pending.insert(.approvals)
            pending.insert(.projects)
        case "run":
            pending.insert(.runs)
            pending.insert(.projects)
        case "agent": pending.insert(.agents)
        case "requirement": pending.insert(.requirements)
        default: return
        }
        if audit.entityKind == "issue", case .agent = audit.actor, let id = audit.entityId { flash(id) }
        scheduleReload()
    }

    private func flash(_ id: Int64) {
        flashing.insert(id)
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            flashing.remove(id)
        }
    }

    /// Coalesces a burst of events into one read of each thing they named.
    private func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            let due = pending
            pending = []
            reloadTask = nil
            guard let server, let company = company?.id else { return }
            if due.contains(.approvals) { approvals = await server.approvals(company: company) ?? approvals }
            if due.contains(.runs) { runs = await server.liveRuns(company: company) ?? runs }
            if due.contains(.agents) { agents = await server.agents(company: company) ?? agents }
            if due.contains(.requirements) { requirements = await server.requirements() ?? requirements }
            if due.contains(.projects) { await reloadProjects() }
        }
    }

    // MARK: - Persisting

    func update(_ change: (inout ServerSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) { documents.setData(data, forKey: ServerSettings.key) }
    }

    private var cursorKey: String? {
        settings.server.map { "\($0)|\(settings.companyID ?? 0)" }
    }

    private var cursor: Int64? { cursorKey.flatMap { settings.cursors[$0] } }

    private func saveCursor(force: Bool) {
        guard let seq = stream?.cursor, let key = cursorKey else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastSaved) >= 1 else { return }
        lastSaved = now
        update { $0.cursors[key] = seq }
    }
}
