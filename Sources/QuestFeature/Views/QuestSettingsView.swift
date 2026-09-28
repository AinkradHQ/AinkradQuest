import SwiftUI
import AppKit
import AinkradAppKit

/// Quest's settings surface — a "Presentation" (pane/overlay) control on the
/// Cardinal HUD kit, mirroring `LeylineSettingsView`. Backed by
/// `HostServices.presentation` (`PluginPresentationControl`): the override
/// takes effect the next time Quest is opened, never morphing an
/// already-open window.
///
/// Also hosts the two root grants (`FolderBookmark.projectsRootKey` /
/// `vaultRootKey`). `projectsRootKey` drives ONLY attachment suggestions at
/// project-creation time — granting it does not attach anything by itself; a
/// project's Overview always has its own "Attach folder…" button
/// (`FolderAttachButton`), independent of this grant. `vaultRootKey` has a
/// SECOND consumer as of the backup work: `BackupSettings` reads and writes
/// through the same bookmark to back up and restore the overlay. This is the
/// ONLY place either grant is set or cleared — `BackupSettings` shows the
/// vault grant read-only and points here to change it, so there is never a
/// second control that can silently diverge from this one.
struct QuestSettingsView: View {
    let presentation: any PluginPresentationControl
    let modeControl: any PluginModeControl
    let documents: PluginDocumentStore
    @Bindable var store: ProjectStore
    @Bindable var registry: ConnectionRegistry
    @Bindable var snapshots: SnapshotStore

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ainkradStatusColors) private var statusColors
    /// Bumped whenever a grant is changed, to re-read `FolderBookmark.grant`.
    /// The grants themselves are NOT cached in `@State` seeded from `init`:
    /// this initializer re-runs on every parent re-render, and anything it
    /// called would run with it.
    @State private var grantRevision = 0
    @State private var error: String?
    /// Hoisted out of `ConnectionsSettings` (its only writer) so the
    /// add-connection modal can be presented from THIS view's root instead of
    /// that section's narrow, offset box — `.ainkradModal` is an overlay that
    /// renders in the modified view's own bounds, so attaching it to the
    /// section clipped it off the window's left edge. Same shape as
    /// `ProjectSettingsSheet` hoisting `pendingSchemePlan` out of
    /// `StatusSchemeEditor`.
    @State private var connectionDraft: ConnectionDraft?
    /// `.ainkradModal` REUSES its content view across a change of the
    /// presented item — without this key, reopening after Cancel would hand
    /// the fresh `ConnectionDraft` init argument to a view that kept the
    /// previous open's stale `@State` draft.
    @State private var connectionDraftToken = UUID()
    /// The backup awaiting a confirmed restore, and its failure message —
    /// hoisted out of `BackupSettings` (its only writer) the same way
    /// `connectionDraft` is hoisted out of `ConnectionsSettings`, so the
    /// confirm dialog presents from this root rather than one of
    /// `BackupSettings`' two inner `AinkradSectionFrame` boxes.
    @State private var pendingRestore: SnapshotFile?
    @State private var restoreError: String?
    /// The project whose corrupt overlay is awaiting a confirmed discard —
    /// hoisted to this root the same way `pendingRestore` is: this is a
    /// destructive action (`OverlayStore.removeOverlay`) and needs the
    /// confirm dialog presented from the settings root, not a narrow section
    /// box. This is the exit `OverlayHealth.writeBlocked`'s own message
    /// promises ("discard it to start fresh") but that, before this fix, had
    /// no UI path to reach.
    @State private var pendingDiscard: UUID?
    /// The vault grant awaiting a confirmed clear (ADDITION A). Clearing it
    /// silently turns off the only protection the overlay has, so it gets the
    /// same treatment as restore/discard — hoisted here rather than presented
    /// from `rootRow` itself, for the identical clipping reason.
    @State private var pendingClearVaultGrant = false

    init(presentation: any PluginPresentationControl,
         modeControl: any PluginModeControl,
         documents: PluginDocumentStore,
         store: ProjectStore, registry: ConnectionRegistry, snapshots: SnapshotStore) {
        self.presentation = presentation
        self.modeControl = modeControl
        self.documents = documents
        self.store = store
        self.registry = registry
        self.snapshots = snapshots
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionFrame(title: "Appearance") {
                VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                    caption("Quest tracks projects and work items per workspace.")

                    // Shared rows, not a local copy: "Open as" and "Open in"
                    // must read the same and sit in the same place everywhere.
                    AinkradSurfaceSettings(appName: "Quest",
                                           presentation: presentation,
                                           mode: modeControl)
                }
            }

            // Same reporting seam as the folder grants below: this view is
            // mounted by the HOST's settings surface, outside `QuestShell`'s
            // `.ainkradToastHost()`, so errors go to this standing banner
            // rather than a toast.
            ConnectionsSettings(registry: registry, store: store,
                               report: { message, _ in error = message },
                               draft: $connectionDraft, draftToken: $connectionDraftToken)

            BackupSettings(snapshots: snapshots, pendingRestore: $pendingRestore,
                           restoreError: $restoreError)

            if !store.overlay.health.affectedProjects.isEmpty {
                AinkradSectionFrame(title: "Corrupt overlays") {
                    VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                        caption("These projects' saved notes could not be read. Restore from a backup above, or discard to start fresh with an empty overlay.")
                        ForEach(Array(store.overlay.health.affectedProjects), id: \.self) { projectID in
                            AinkradFormRow(title: projectName(projectID), help: "Overlay could not be read.") {
                                AinkradButton(title: "Discard…", style: .danger) {
                                    pendingDiscard = projectID
                                }
                            }
                        }
                    }
                }
            }

            AinkradSectionFrame(title: "Folder grants") {
                VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                    caption("Every project's Overview also has its own Attach folder… button, which works whether or not you set anything here.")

                    rootRow(title: "Projects folder",
                           help: "Used only to suggest a matching repo or folder by name when you create a project — nothing else reads or writes it.",
                           key: FolderBookmark.projectsRootKey)

                    rootRow(title: "Vault folder",
                           help: "Two uses: suggests a matching vault folder by name when you create a project, and is where Quest backs up and restores your notes, personal priority and time entries — see Backups above.",
                           key: FolderBookmark.vaultRootKey)

                    // A banner, not a toast: this view is mounted by the HOST's
                    // settings surface, outside `QuestShell`'s
                    // `.ainkradToastHost()`, so there is no `report` path to
                    // reach from here. A failed grant is also a standing
                    // condition — suggestions stay broken until it is fixed —
                    // which a toast would expire out from under.
                    if let error {
                        AinkradBanner(message: error, status: .danger) { self.error = nil }
                    }
                }
            }
        }
        .padding(AinkradSpacing.lg)
        // Presented HERE, at the settings root, rather than inside
        // `ConnectionsSettings` — see `connectionDraft`'s doc comment. This
        // gives the overlay the full settings surface as its bounds instead
        // of one section's narrow box, so the editor is centered and
        // contained rather than clipped off the left edge.
        .ainkradModal(isPresented: Binding(get: { connectionDraft != nil },
                                           set: { if !$0 { connectionDraft = nil } })) {
            if let current = connectionDraft {
                ConnectionEditor(draft: current, registry: registry,
                                 report: { message, _ in error = message },
                                 onClose: { connectionDraft = nil })
                    .id(connectionDraftToken)
            }
        }
        // Restore is the most destructive action Quest offers — it replaces
        // the live overlay with the snapshot's — so it gets a confirm dialog,
        // hoisted to this root for the same reason `connectionDraft`'s modal
        // is: `.ainkradConfirmDialog`/`.ainkradModal` render in the MODIFIED
        // view's own bounds, and `BackupSettings`' two `AinkradSectionFrame`
        // boxes are narrow, offset boxes, not this window.
        .ainkradConfirmDialog(isPresented: Binding(get: { pendingRestore != nil },
                                                   set: { if !$0 { pendingRestore = nil } }),
                              title: "Restore this backup?",
                              message: pendingRestore.map {
                                  "This replaces your current notes, personal priority and time entries "
                                      + "with the backup from \(SnapshotAge.describe($0.takenAt)). "
                                      + "Anything changed since then will be lost. This cannot be undone."
                              } ?? "",
                              confirmTitle: "Restore",
                              isDestructive: true) {
            if let file = pendingRestore {
                performRestore(file)
            }
            pendingRestore = nil
        }
        // Discarding a corrupt overlay replaces it with nothing — irreversible
        // by definition, since the whole reason it is offered is that the
        // bytes could not be read in the first place. Same hoisting reasoning
        // as `pendingRestore`.
        .ainkradConfirmDialog(isPresented: Binding(get: { pendingDiscard != nil },
                                                   set: { if !$0 { pendingDiscard = nil } }),
                              title: "Discard this project's notes?",
                              message: pendingDiscard.map {
                                  "\(projectName($0))'s saved notes could not be read and cannot be recovered from here. "
                                      + "Discarding replaces them with an empty overlay so you can start fresh, "
                                      + "or restore from a backup above instead. This cannot be undone."
                              } ?? "",
                              confirmTitle: "Discard",
                              isDestructive: true) {
            if let projectID = pendingDiscard {
                store.overlay.removeOverlay(for: projectID)
            }
            pendingDiscard = nil
        }
        // ADDITION A: clearing the vault grant silently turns off the only
        // protection the overlay has — the age indicator would then quietly
        // report a backup that stopped, which is the exact failure this
        // milestone exists to prevent. Confirmed here, at the root, for the
        // same clipping reason as the two dialogs above. The PROJECTS grant
        // deliberately gets no such confirm — see `clearRoot`.
        .ainkradConfirmDialog(isPresented: $pendingClearVaultGrant,
                              title: "Turn off backups?",
                              message: "Clearing the vault folder stops Quest from backing up your "
                                  + "notes, personal priority and time entries. Existing backups in "
                                  + "that folder are not deleted, but no new ones will be written "
                                  + "until you grant a vault folder again.",
                              confirmTitle: "Clear",
                              isDestructive: true) {
            FolderBookmark.clear(forKey: FolderBookmark.vaultRootKey, in: documents)
            grantRevision += 1
        }
    }

    /// A best-effort display name for a project id that may no longer be in
    /// `store.projects`/`trashedProjects` (e.g. already purged) — falls back
    /// to a shortened id rather than crashing or showing nothing.
    private func projectName(_ projectID: UUID) -> String {
        (store.projects + store.trashedProjects).first { $0.id == projectID }?.name
            ?? "Project \(projectID.uuidString.prefix(8))"
    }

    private func performRestore(_ file: SnapshotFile) {
        do {
            try snapshots.restore(from: file)
            restoreError = nil
        } catch let failure as SnapshotError {
            restoreError = failure.message
        } catch {
            restoreError = error.localizedDescription
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(AinkradFontResolver.font(.body, typography: typo))
            .foregroundStyle(theme.foreground.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Rendering this row must never acquire a scoped resource — it reads
    /// `FolderBookmark.grant`, which resolves for display only. `grantRevision`
    /// is read so SwiftUI re-runs the row after Choose…/Clear.
    private func rootRow(title: String, help: String, key: String) -> some View {
        _ = grantRevision
        let grant = FolderBookmark.grant(forKey: key, in: documents)
        return AinkradFormRow(title: title, help: help) {
            HStack(spacing: AinkradSpacing.sm) {
                VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                    Text(Self.pathText(grant))
                        .font(AinkradFontResolver.font(.mono, typography: typo))
                        .foregroundStyle(theme.foreground.opacity(0.8))
                        .lineLimit(1).truncationMode(.middle)
                    // A grant that no longer resolves is NOT the same as no
                    // grant: without this the user sees "Not set", cannot tell
                    // why suggestions stopped, and (previously) had no Clear
                    // button to fix it.
                    if case .unresolvable = grant {
                        Text("This folder can no longer be found — it was moved, renamed, or deleted. Choose it again, or clear it.")
                            .font(.caption)
                            .foregroundStyle(statusColors.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AinkradButton(title: "Choose…", style: .secondary) { pickRoot(key: key) }
                // Available for a broken grant too, not just a working one.
                if grant != .notGranted {
                    AinkradButton(title: "Clear", style: .ghost) { clearRoot(key: key) }
                }
            }
        }
    }

    private static func pathText(_ grant: FolderBookmark.Grant) -> String {
        switch grant {
        case .notGranted: "Not set"
        case .granted(let path): path
        case .unresolvable(let path): path ?? "Previously granted folder"
        }
    }

    private func pickRoot(key: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FolderBookmark.save(url, forKey: key, in: documents)
            grantRevision += 1
            error = nil
        } catch {
            self.error = "Could not save that folder: \(error.localizedDescription)"
        }
    }

    private func clearRoot(key: String) {
        // The vault grant drives backups now (ADDITION A) — clearing it must
        // be confirmed, unlike the projects grant, which still only feeds
        // creation-time suggestions and costs nothing to clear. A confirm on
        // the projects grant too would just be noise that teaches the user to
        // click through the one that matters.
        if key == FolderBookmark.vaultRootKey {
            pendingClearVaultGrant = true
            return
        }
        FolderBookmark.clear(forKey: key, in: documents)
        grantRevision += 1
    }
}
