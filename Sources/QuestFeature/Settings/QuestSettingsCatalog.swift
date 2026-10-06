import AinkradAppKit
import AppKit
import SwiftUI

/// Quest's settings as DECLARED fields, so the host draws them in the shared
/// settings style, with its Appearance tab first.
///
/// Destructive actions (remove a connection, restore or discard notes, turn
/// off backups) confirm through `QuestConfirm` — a declared action row has no
/// dialog of its own.
@MainActor
enum QuestSettingsCatalog {
    struct Context {
        let documents: PluginDocumentStore
        let store: ProjectStore
        let registry: ConnectionRegistry
        let snapshots: SnapshotStore
        let state: QuestSettingsState
    }

    static func page(_ c: Context) -> SettingsPage {
        let root = SettingsPath([QuestApp.id])
        if c.state.entries == nil { c.state.refreshBackups(c.snapshots) }
        return SettingsPage(
            path: root, title: "Quest", icon: QuestApp.icon, group: .installedApps, order: 0,
            groups: [connections(c, root), backups(c, root), folders(c, root)],
            appID: QuestApp.id)
    }

    // MARK: - Backups

    private static func backups(_ c: Context, _ root: SettingsPath) -> SettingsGroup {
        let group = root.appending("backups")
        _ = c.state.revision
        let grant = c.snapshots.vaultGrant()
        var fields = [
            folderRow(
                c, path: group.appending("vault"), label: "Vault folder",
                help: vaultHelp(grant), key: FolderBookmark.vaultRootKey)
        ]
        if grant != .notGranted {
            fields.append(
                SettingsField(
                    path: group.appending("vault-clear"), label: "Turn off backups",
                    help: "Clears the vault folder. Existing backups there are kept.",
                    kind: .action(title: "Clear…") {
                        guard
                            QuestConfirm.ask(
                                "Turn off backups?",
                                "Clearing the vault folder stops Quest from backing up your notes, personal "
                                    + "priority and time entries. Existing backups in that folder are not deleted, "
                                    + "but no new ones will be written until you grant a vault folder again.",
                                confirm: "Clear")
                        else { return }
                        FolderBookmark.clear(forKey: FolderBookmark.vaultRootKey, in: c.documents)
                        c.state.changed(c.snapshots)
                    }))
        }
        fields.append(
            SettingsField(
                path: group.appending("now"), label: "Last backup",
                help: [SnapshotAge.describe(c.state.age), c.snapshots.lastError].compactMap { $0 }.joined(
                    separator: " — "),
                keywords: ["backup", "snapshot"],
                kind: .action(title: "Back up now") {
                    _ = c.snapshots.snapshotNow()
                    c.state.changed(c.snapshots)
                }))
        for entry in c.state.entries ?? [] {
            switch entry {
            case .readable(let file):
                fields.append(
                    SettingsField(
                        path: group.appending("restore-\(file.url.lastPathComponent)"),
                        label: SnapshotAge.describe(file.takenAt),
                        help: "Backup · \(file.projectCount) project\(file.projectCount == 1 ? "" : "s")",
                        keywords: ["restore", "backup"],
                        kind: .action(title: "Restore…") { restore(file, c) }))
            case .damaged(let url, let filename):
                fields.append(
                    SettingsField(
                        path: group.appending("damaged-\(url.lastPathComponent)"), label: filename,
                        help: "This backup is damaged and cannot be restored.",
                        kind: .shortcut(.constant("Damaged"))))
            }
        }
        for projectID in c.store.overlay.health.affectedProjects.sorted(by: { $0.uuidString < $1.uuidString }) {
            let name = projectName(projectID, c.store)
            fields.append(
                SettingsField(
                    path: group.appending("corrupt-\(projectID.uuidString)"), label: name,
                    help:
                        "This project's saved notes could not be read. Restore a backup above, or discard to start fresh.",
                    kind: .action(title: "Discard…") {
                        guard
                            QuestConfirm.ask(
                                "Discard this project's notes?",
                                "\(name)'s saved notes could not be read and cannot be recovered from here. "
                                    + "Discarding replaces them with an empty overlay so you can start fresh, or "
                                    + "restore from a backup instead. This cannot be undone.",
                                confirm: "Discard")
                        else { return }
                        c.store.overlay.removeOverlay(for: projectID)
                    }))
        }
        return SettingsGroup(
            path: group, title: "Backups",
            footerNote: c.state.backupMessage
                ?? "Your notes, personal priority and time entries — the things a re-sync can never "
                + "rebuild — are backed up to your vault folder.",
            fields: fields)
    }

    private static func restore(_ file: SnapshotFile, _ c: Context) {
        guard
            QuestConfirm.ask(
                "Restore this backup?",
                "This replaces your current notes, personal priority and time entries with the backup "
                    + "from \(SnapshotAge.describe(file.takenAt)). Anything changed since then will be lost. "
                    + "This cannot be undone.",
                confirm: "Restore")
        else { return }
        do {
            try c.snapshots.restore(from: file)
            c.state.backupMessage = nil
        } catch {
            c.state.backupMessage = error.localizedDescription
        }
        c.state.changed(c.snapshots)
    }

    private static func vaultHelp(_ grant: FolderBookmark.Grant) -> String {
        switch grant {
        case .notGranted:
            "Not set — backups are off. Choose a vault folder to back up your notes and priorities; "
                + "it is also where Quest looks for a matching folder when you create a project."
        case .granted(let path):
            "\(path) — backups are written here, keeping the last \(SnapshotWriter.keep)."
        case .unresolvable(let path):
            "\(path ?? "The granted folder") can no longer be found — it was moved, renamed or "
                + "deleted. Backups have STOPPED. Choose it again, or turn backups off."
        }
    }

    // MARK: - Folders

    private static func folders(_ c: Context, _ root: SettingsPath) -> SettingsGroup {
        let group = root.appending("folders")
        _ = c.state.revision
        let key = FolderBookmark.projectsRootKey
        let grant = FolderBookmark.grant(forKey: key, in: c.documents)
        var fields = [
            folderRow(
                c, path: group.appending("projects"), label: "Projects folder",
                help: "\(pathText(grant)). Used only to suggest a matching repo or folder by name when "
                    + "you create a project — nothing else reads or writes it.",
                key: key)
        ]
        if grant != .notGranted {
            fields.append(
                SettingsField(
                    path: group.appending("projects-clear"), label: "Clear projects folder",
                    help: "Stops name suggestions. Nothing attached to a project changes.",
                    kind: .action(title: "Clear") {
                        FolderBookmark.clear(forKey: key, in: c.documents)
                        c.state.changed(c.snapshots)
                    }))
        }
        return SettingsGroup(
            path: group, title: "Folders",
            footerNote: c.state.folderMessage
                ?? "Every project's Overview also has its own Attach folder… button, which works "
                + "whether or not you set anything here.",
            fields: fields)
    }

    private static func folderRow(
        _ c: Context, path: SettingsPath, label: String,
        help: String, key: String
    ) -> SettingsField {
        SettingsField(
            path: path, label: label, help: help,
            keywords: ["folder", "grant", label.lowercased()],
            kind: .action(title: "Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try FolderBookmark.save(url, forKey: key, in: c.documents)
                    c.state.folderMessage = nil
                } catch {
                    c.state.folderMessage = "Could not save that folder: \(error.localizedDescription)"
                }
                c.state.changed(c.snapshots)
            })
    }

    static func pathText(_ grant: FolderBookmark.Grant) -> String {
        switch grant {
        case .notGranted: "Not set"
        case .granted(let path): path
        case .unresolvable(let path): "\(path ?? "Previously granted folder") (can no longer be found)"
        }
    }

    static func projectName(_ id: UUID, _ store: ProjectStore) -> String {
        (store.projects + store.trashedProjects).first { $0.id == id }?.name
            ?? "Project \(id.uuidString.prefix(8))"
    }
}

/// What the declared page must remember between the host's rebuilds of it:
/// the add-connection draft, the memoized backup list (listing acquires the
/// vault's scoped resource, so never per render) and the last message per tab.
@MainActor @Observable
final class QuestSettingsState {
    var draft = ConnectionDraft(provider: .linear)
    let picker = GitHubAccountPickerState()
    var entries: [SnapshotEntry]?
    var age: Date?
    var revision = 0
    var connectionMessage: String?
    var backupMessage: String?
    var folderMessage: String?

    func refreshBackups(_ snapshots: SnapshotStore) {
        let listed = snapshots.listSnapshots()
        entries = listed
        let onDisk = listed.compactMap { entry -> Date? in
            if case .readable(let file) = entry { return file.takenAt }
            return nil
        }.max()
        age = [snapshots.lastSnapshotAt, onDisk].compactMap { $0 }.max()
    }

    /// After any action: re-read grants and the backup list.
    func changed(_ snapshots: SnapshotStore) {
        revision += 1
        refreshBackups(snapshots)
    }
}

/// A native confirmation for a declared destructive action.
@MainActor
enum QuestConfirm {
    static func ask(_ title: String, _ message: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
