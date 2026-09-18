import SwiftUI
import AinkradAppKit

public struct QuestApp: AinkradApp {
    public static let id = "quest"
    public static let displayName = "Quest"
    public static let icon = "checklist"

    /// Keyed by the host-minted instance id rather than
    /// `ObjectIdentifier(host)` — an address of a box around a non-class-bound
    /// existential, reusable after free, and never evicted. See
    /// `PluginInstanceStorage`.
    @MainActor private static let stores = PluginInstanceStorage<ProjectStore>()

    /// The instance key for `host`.
    ///
    /// A generation-8 host mints one. A generation-7 host does not implement
    /// `PluginInstanceIdentity`, so fall back to the OLD per-host object
    /// identity rather than to one shared id — collapsing every legacy host
    /// onto a single key would make two hosts share a store, which is a
    /// regression rather than a fallback. The address-reuse hazard stays only
    /// on the legacy path, exactly as before, and is gone on generation 8.
    @MainActor private static func instance(of host: HostServices) -> PluginInstanceID {
        if let identified = host as? PluginInstanceIdentity { return identified.instanceID }
        let key = ObjectIdentifier(host as AnyObject)
        if let existing = legacyIDs[key] { return existing }
        let minted = PluginInstanceID()
        legacyIDs[key] = minted
        return minted
    }
    @MainActor private static var legacyIDs: [ObjectIdentifier: PluginInstanceID] = [:]

    /// Cached per host, the same shape as `stores`: this MUST be the single
    /// `OverlayStore` instance for the host's repository. `ProjectStore` no
    /// longer builds its own — a second instance over the same repository
    /// would be a second in-memory cache and a second `HubConfig` copy, with
    /// writes through one invisible to the other until reload.
    @MainActor private static let overlays = PluginInstanceStorage<OverlayStore>()

    @MainActor private static func overlay(for host: HostServices) -> OverlayStore {
        overlays.value(for: instance(of: host)) {
            let store = OverlayStore(repository: DocumentProjectRepository(documents: host.documents))
            let reporter = QuestSignalReporter(signals: host.signals)
            // Reports the TRANSITION, not the state. Re-evaluating health on
            // every write would otherwise re-file the same corruption
            // endlessly; only newly-affected projects are news.
            store.onHealthChanged = { new, old in
                for projectID in new.affectedProjects.subtracting(old.affectedProjects) {
                    // Resolved from ProjectStore, which is the only thing that
                    // knows a project's NAME — OverlayStore deals in ids.
                    // Looked up inside the closure rather than captured: this
                    // runs long after construction, and `store(for:)` builds
                    // the overlay store, so capturing it here would recurse.
                    let name = Self.store(for: host).projects
                        .first { $0.id == projectID }?.name ?? "A project"
                    reporter.overlayUnreadable(projectName: name, projectID: projectID)
                }
                if case .writeFailed(let reason) = new {
                    reporter.overlayWriteFailed(reason: reason)
                }
            }
            return store
        }
    }

    @MainActor private static func store(for host: HostServices) -> ProjectStore {
        stores.value(for: instance(of: host)) {
            ProjectStore(repository: DocumentProjectRepository(documents: host.documents),
                         overlay: overlay(for: host))
        }
    }

    /// Cached per host, the same shape as `stores`: the registry holds
    /// in-memory state (connections, `persistenceFailure`) that must be the
    /// SAME instance the settings view mutates, not a fresh copy reloaded
    /// from disk on every settings open.
    @MainActor private static let registries = PluginInstanceStorage<ConnectionRegistry>()

    @MainActor private static func registry(for host: HostServices) -> ConnectionRegistry {
        registries.value(for: instance(of: host)) {
            ConnectionRegistry(repository: DocumentProjectRepository(documents: host.documents),
                              credentials: KeychainCredentialStore())
        }
    }

    /// Cached per host, the same shape as `stores`/`registries`: it holds
    /// `lastSnapshotAt`/`lastError`, standing state the settings view must
    /// read and mutate through the same instance, not a fresh one reloaded
    /// on every settings open.
    @MainActor private static let snapshotStores = PluginInstanceStorage<SnapshotStore>()

    @MainActor private static func snapshotStore(for host: HostServices) -> SnapshotStore {
        snapshotStores.value(for: instance(of: host)) {
            let projectStore = store(for: host)
            let snapshots = SnapshotStore(overlay: overlay(for: host), documents: host.documents,
                                          projectIDs: { [weak projectStore] in
                                              guard let projectStore else { return [] }
                                              return (projectStore.projects + projectStore.trashedProjects).map(\.id)
                                          })
            // BLOCKER 1: the design's cadence — debounced on overlay change,
            // roughly five minutes of quiet, plus one final write on
            // teardown if anything changed — was never implemented. Started
            // here, once per instance, rather than in `SnapshotStore.init`,
            // so a store built by a test never schedules a timer of its own.
            snapshots.startAutoBackup()
            return snapshots
        }
    }

    public static func makeRootView(host: HostServices) -> AnyView {
        makeRootView(host: host, mode: .advanced)
    }

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(QuestSettingsView(presentation: host.presentation, modeControl: host.mode,
                                  documents: host.documents,
                                  store: store(for: host), registry: registry(for: host),
                                  snapshots: snapshotStore(for: host)))
    }

    public static func chromeFill(host: HostServices) -> Color? {
        host.theme.tokens.background
    }

    /// The per-host MCP server, created once and cached — the same shape as
    /// `stores`, keyed by the same instance id, because the server MUST read
    /// the store the window is showing. Building a fresh `ProjectStore` here
    /// would hand the assistant a detached second copy that reloads from disk
    /// and never sees a task the user just typed.
    @MainActor private static let mcpServers = PluginInstanceStorage<MCPAppServer>()

    @MainActor static func mcpServer(for host: HostServices) -> MCPAppServer {
        mcpServers.value(for: instance(of: host)) {
            let operations = QuestMCPOperations(store: store(for: host))
            // Every agent tool call passes through this one closure, which is
            // what makes "the assistant changed something" reportable without
            // touching the twenty `document.activity.append` sites. Reads are
            // excluded by name: list_projects is not news.
            let reporter = QuestSignalReporter(signals: host.signals)
            let (server, failures) = QuestMCPServer.make(appID: id) { operation, arguments in
                let result = await operations.run(operation: operation, arguments: arguments)
                QuestAgentActivityReporter.report(operation: operation,
                                                  result: result,
                                                  store: store(for: host),
                                                  reporter: reporter)
                return result
            }
            // A dropped tool is a silently missing capability — say so rather
            // than let the assistant just never see it.
            if !failures.isEmpty {
                host.log.error("Quest MCP: tools rejected — \(failures.joined(separator: ", "))")
            }
            return server
        }
    }
}

/// Publishes Quest's projects and work items to the host assistant. Cached
/// per host by `mcpServer(for:)`, so the assistant reads the same store the
/// window shows.
extension QuestApp: AinkradAppMCP {
    public static func makeMCPServer(host: HostServices) -> MCPAppServer { mcpServer(for: host) }
}

/// Generation 8: release a closed instance's store rather than let it linger
/// (and its cached documents with it) for the rest of the process.
extension QuestApp: AinkradAppTeardown {
    public static func teardown(instance: PluginInstanceID) {
        stores.remove(instance)
        overlays.remove(instance)
        registries.remove(instance)
        // BLOCKER 1: this is the closest thing to an "app is going away" hook
        // a plugin gets — there is no separate process-termination signal
        // exposed to `AinkradApp`/`HostServices`. It fires when the HOST
        // closes this instance, which covers the window-closed case; it does
        // NOT cover the whole process being killed out from under an open
        // instance (force-quit, crash), which no hook here can catch. Flush
        // BEFORE removing, while `snapshots` still has its `overlay`/timer.
        snapshotStores.remove(instance)?.flushOnTeardown()
        // The MCP server's tool closures capture the operations layer, which
        // captures this instance's store. Leaving it registered would let the
        // assistant keep driving an app the user shut.
        mcpServers.remove(instance)
    }
}

/// Generation 11: Quest's basic mode is Today, without the shell around it.
extension QuestApp: AinkradAppModes {
    public static func makeRootView(host: HostServices, mode: PluginMode) -> AnyView {
        switch mode {
        case .basic:
            // `.ainkradToastHost()` is applied here as well as in QuestShell:
            // Today reports failures through the toast center, and without a
            // host those reports go nowhere — a failed capture would look like
            // a successful one.
            return AnyView(QuestBasicView(store: store(for: host)).ainkradToastHost())
        case .advanced:
            return AnyView(QuestShell(store: store(for: host), registry: registry(for: host),
                                      theme: host.theme, documents: host.documents))
        // Resilient enum: fall back to advanced, never to a stripped view for a
        // mode this build does not understand.
        @unknown default:
            return AnyView(QuestShell(store: store(for: host), registry: registry(for: host),
                                      theme: host.theme, documents: host.documents))
        }
    }
}
