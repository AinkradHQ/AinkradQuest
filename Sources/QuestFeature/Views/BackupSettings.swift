import AinkradAppKit
import Foundation
import SwiftUI

/// Backup status and restore surface: the grant state (with all three cases
/// distinguished — see `FolderBookmark.Grant`), the last-snapshot age, a
/// manual "Back up now", and the restore list.
///
/// Restore is the most destructive action Quest offers — it replaces the live
/// overlay with the snapshot's, by design — so it gets the same confirm-dialog
/// treatment as removing a connection. Unlike `ConnectionsSettings`' own
/// delete confirm (which is fine attached at ITS root — the clipping bug is
/// specific to `.ainkradModal`, a full editor), this one is hoisted one level
/// further, to `QuestSettingsView`'s own root, via `pendingRestore`/
/// `restoreError` — the same `@Binding` shape `QuestSettingsView` uses to
/// hoist `connectionDraft` out of `ConnectionsSettings`. `BackupSettings`
/// itself never presents `.ainkradConfirmDialog`.
///
/// This view does NOT present its own "Choose…"/"Clear" for the vault
/// folder. `FolderBookmark.vaultRootKey` is ONE grant with two consumers —
/// this view's backups and `QuestSettingsView`'s attachment suggestions — and
/// an earlier round of this view had its own picker here, which let the same
/// bookmark be set or cleared from two independent-looking controls with no
/// indication they shared state. The grant now lives only in "Folder grants"
/// (`QuestSettingsView.rootRow`); this section reads it read-only and points
/// there to change it.
struct BackupSettings: View {
    @Bindable var snapshots: SnapshotStore
    /// The snapshot awaiting a confirmed restore, owned by `QuestSettingsView`
    /// so its confirm dialog can be presented from the settings root.
    @Binding var pendingRestore: SnapshotFile?
    @Binding var restoreError: String?

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ainkradStatusColors) private var statusColors

    /// Bumped after Choose…/Back up now/restore so the grant and the restore
    /// list are re-read. Same shape as `QuestSettingsView.grantRevision`.
    @State private var revision = 0
    /// Memoized `listSnapshots()` result (MAJOR 4). `rootRow`'s own doc
    /// comment states rendering must never acquire a scoped resource, and
    /// `listSnapshots()` enters `FolderBookmark.withAccess` plus a directory
    /// enumeration and up to `SnapshotWriter.keep` JSON decodes — calling it
    /// directly in `body` did that on every single body pass. Recomputed only
    /// in `refreshEntries()`, driven by `revision`, matching how `grantRow`
    /// re-reads the grant on the same signal.
    @State private var cachedEntries: [SnapshotEntry] = []
    /// The displayed age (BLOCKER 2), derived from `cachedEntries` rather than
    /// calling `snapshots.lastBackupAt()` (which itself calls `listSnapshots()`)
    /// directly in `body` — same scoped-resource-in-render concern as above.
    @State private var cachedAge: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            AinkradSectionFrame(title: "Backups") {
                VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                    caption(
                        "Your notes, personal priority and time entries — the things a re-sync can never rebuild — are backed up to your vault folder."
                    )

                    grantRow

                    AinkradFormRow(title: "Last backup", help: SnapshotAge.describe(cachedAge)) {
                        AinkradButton(title: "Back up now", style: .secondary) { backUpNow() }
                    }

                    if let failure = snapshots.lastError {
                        AinkradBanner(message: failure, status: .danger)
                    }
                }
            }

            AinkradSectionFrame(title: "Restore") {
                VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                    if cachedEntries.isEmpty {
                        caption("No backups yet.")
                    } else {
                        ForEach(cachedEntries) { entry in
                            restoreRow(entry)
                        }
                    }

                    if let restoreError {
                        AinkradBanner(message: restoreError, status: .danger) { self.restoreError = nil }
                    }
                }
            }
        }
        // No `.ainkradConfirmDialog` here — see the type doc comment. Restoring
        // still bumps `revision` after `QuestSettingsView` applies it, via
        // `onChange` below.
        .onChange(of: pendingRestore) { old, new in
            // Fires once the confirm dialog (owned by the parent) resolves
            // `pendingRestore` back to nil after a restore — re-read the
            // grant/list/age so the UI reflects what just happened.
            if old != nil && new == nil { revision += 1 }
        }
        // Loads the memoized list/age once on first appearance...
        .onAppear { refreshEntries() }
        // ...and again whenever something that could have changed the vault's
        // contents bumps `revision` (Back up now, a resolved restore).
        .onChange(of: revision) { _, _ in refreshEntries() }
    }

    /// The ONLY place `listSnapshots()`/`lastBackupAt()` are called — never
    /// from `body` (MAJOR 4). Runs from `.onAppear`/`.onChange`, not from a
    /// render pass, so acquiring the vault's scoped resource here is fine.
    private func refreshEntries() {
        cachedEntries = snapshots.listSnapshots()
        let onDisk = cachedEntries.compactMap { entry -> Date? in
            if case .readable(let file) = entry { return file.takenAt }
            return nil
        }.max()
        cachedAge = [snapshots.lastSnapshotAt, onDisk].compactMap { $0 }.max()
    }

    // MARK: - Grant state

    /// Read-only: the vault folder itself is granted/changed/cleared only in
    /// "Folder grants" below, so there is exactly one control that can ever
    /// mutate `FolderBookmark.vaultRootKey`. See the type doc comment.
    private var grantRow: some View {
        _ = revision
        let grant = snapshots.vaultGrant()
        return AinkradFormRow(title: "Vault folder", help: grantHelp(grant)) {
            VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                Text(grantPathText(grant))
                    .font(AinkradFontResolver.font(.mono, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle)
                if case .unresolvable = grant {
                    // Must never read as "not configured" — the user
                    // granted a folder and backups have silently stopped,
                    // which is a very different problem from never having
                    // set one up.
                    Text(
                        "This folder can no longer be found — it was moved, renamed, or deleted. Backups have STOPPED. Fix it under Folder grants → Vault folder below."
                    )
                    .font(.caption)
                    .foregroundStyle(statusColors.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// This is the DEFAULT state on a fresh install, not an edge case — most
    /// users will read this before ever granting anything, so it must say
    /// plainly that backups are off and how to turn them on — pointing at
    /// "Folder grants", the only place that can change it.
    private func grantHelp(_ grant: FolderBookmark.Grant) -> String {
        switch grant {
        case .notGranted:
            "Backups are off. Set a vault folder under Folder grants → Vault folder below to start backing up your notes and priorities."
        case .granted:
            "Backups are written here, keeping the last \(SnapshotWriter.keep)."
        case .unresolvable:
            "Backups have stopped because this folder can no longer be found."
        }
    }

    private func grantPathText(_ grant: FolderBookmark.Grant) -> String {
        switch grant {
        case .notGranted: "Not set — backups are off"
        case .granted(let path): path
        case .unresolvable(let path): path ?? "Previously granted folder"
        }
    }

    // MARK: - Restore list

    private func restoreRow(_ entry: SnapshotEntry) -> some View {
        switch entry {
        case .readable(let file):
            return AnyView(
                AinkradFormRow(
                    title: SnapshotAge.describe(file.takenAt),
                    help: "\(file.projectCount) project\(file.projectCount == 1 ? "" : "s")"
                ) {
                    AinkradButton(title: "Restore…", style: .secondary) { pendingRestore = file }
                })
        case .damaged(_, let filename):
            return AnyView(
                AinkradFormRow(
                    title: filename,
                    help: "This backup is damaged and cannot be restored."
                ) {
                    Text("Damaged")
                        .font(.caption)
                        .foregroundStyle(statusColors.danger)
                })
        }
    }

    // MARK: - Actions

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(AinkradFontResolver.font(.body, typography: typo))
            .foregroundStyle(theme.foreground.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func backUpNow() {
        _ = snapshots.snapshotNow()
        revision += 1
    }
}
