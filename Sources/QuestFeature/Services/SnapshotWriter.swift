import Foundation
import os

public enum SnapshotError: Error, Equatable, Sendable, LocalizedError {
    case vaultNotGranted
    case vaultUnresolvable(String?)
    case writeFailed(String)
    case unreadable(String)
    case unsupportedVersion(Int)
    /// MINOR 7: rotation sorts by filename, i.e. by wall-clock at write time.
    /// A backwards clock adjustment can make a snapshot JUST written sort
    /// oldest and be deleted by the very `rotate` call that follows its own
    /// write. Thrown when the file this write produced is gone after
    /// rotating, so `snapshotNow` reports failure instead of `true` for a
    /// backup that no longer exists.
    case rotatedAwayImmediately
    /// Restore was refused before touching anything: at least one project in
    /// the snapshot maps onto a currently-unreadable overlay, and writing
    /// over it would destroy the corrupt bytes a human might still salvage.
    /// Checked BEFORE any project is replaced, so a restore never half-lands.
    case restoreBlocked([UUID])

    /// Written to be read by a person AND by the assistant, matching
    /// `QuestError.message`'s style.
    public var message: String {
        switch self {
        case .vaultNotGranted:
            "Backups are off because no vault folder has been granted. "
                + "Choose one in Quest's settings to start backing up your notes and priorities."
        case .vaultUnresolvable(let path):
            "Your vault folder could not be found"
                + (path.map { " at \($0)" } ?? "")
                + ". Backups have stopped. Grant the folder again in Quest's settings."
        case .writeFailed(let reason):
            "The backup could not be written: \(reason)"
        case .unreadable(let reason):
            "That backup file could not be read: \(reason)"
        case .unsupportedVersion(let version):
            "That backup was written by a newer version of Quest (format \(version)). "
                + "Update Quest to restore it."
        case .rotatedAwayImmediately:
            "The backup was written but then immediately deleted by cleanup — this can happen after "
                + "a system clock change. Check your Mac's date and time, then back up again."
        case .restoreBlocked(let ids):
            "Restore did not run: \(ids.count) project\(ids.count == 1 ? "" : "s") in this backup "
                + "could not be restored because its current overlay is corrupt. "
                + "Discard the corrupt overlay in Quest's settings, then restore again. "
                + "Nothing was changed."
        }
    }

    /// `LocalizedError` routes through `message`, so a caller that only knows
    /// `Error.localizedDescription` shows the same text.
    public var errorDescription: String? { message }
}

/// Writes snapshots into the vault, atomically, keeping a bounded rotation.
public enum SnapshotWriter {
    public static let directoryName = "Quest Snapshots"
    public static let keep = 5

    /// Sortable, collision-resistant, and readable in a file listing. The
    /// random suffix exists because a debounce can fire twice within one
    /// second; without it the second write would overwrite the first and the
    /// rotation would hold four distinct snapshots instead of five.
    public static func filename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let suffix = String(UUID().uuidString.prefix(4))
        return "quest-overlay-\(formatter.string(from: date))-\(suffix).json"
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted and pretty-printed on purpose: this file exists to be read by
        // a person when everything else has failed, and a stable key order
        // makes two snapshots diffable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    @discardableResult
    public static func write(_ snapshot: OverlaySnapshot, into directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent(filename(for: snapshot.takenAt))
        let temporary = destination.appendingPathExtension("tmp")
        do {
            let data = try encoder().encode(snapshot)
            // Temp-then-rename. A crash mid-write must never leave a truncated
            // snapshot in place of a good one: a corrupt backup is worse than a
            // stale one, because it is discovered only when it is needed.
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            removeLogged(temporary, "the failed write's temporary file")
            throw SnapshotError.writeFailed(error.localizedDescription)
        }
    }

    /// A `.tmp` file this old cannot be a write in flight — `write` only ever
    /// holds one open between `data.write` and `moveItem`, which is a
    /// millisecond-scale gap, not minutes. Anything older survived a hard
    /// kill and is abandoned litter, not another process's in-progress write.
    static let staleTempAge: TimeInterval = 5 * 60

    /// Deletes the oldest snapshots beyond `keeping`, newest first by filename,
    /// and sweeps abandoned `.tmp` files left by a write that was killed
    /// between `data.write` and `moveItem` (the writer's own `catch` cleans
    /// those up on a handled failure, but a hard kill skips that entirely, and
    /// `rotate`'s normal filter ignores `.tmp` names, so without this sweep
    /// they accumulate forever).
    ///
    /// Called only AFTER a successful write, so a failed write never costs the
    /// user an existing backup.
    @discardableResult
    public static func rotate(in directory: URL, keeping: Int = keep) throws -> [URL] {
        let allNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        // Only ever touch files this writer itself created — this directory
        // lives in the user's vault and must not delete anything it did not
        // write, no matter how old.
        let staleTemps = allNames.filter { $0.hasPrefix("quest-overlay-") && $0.hasSuffix(".json.tmp") }
        for name in staleTemps {
            let url = directory.appendingPathComponent(name)
            guard
                let modified = try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            else { continue }
            if Date().timeIntervalSince(modified) >= staleTempAge {
                removeLogged(url, "a stale temporary file")
            }
        }

        let names =
            allNames
            .filter { $0.hasPrefix("quest-overlay-") && $0.hasSuffix(".json") }
            .sorted(by: >)
        let urls = names.map { directory.appendingPathComponent($0) }
        for url in urls.dropFirst(keeping) {
            removeLogged(url, "a rotated-out backup")
        }
        return Array(urls.prefix(keeping))
    }

    /// Best-effort cleanup: a file that will not delete is retried by the next
    /// rotation and costs no backup, so it is logged rather than thrown.
    private static func removeLogged(_ url: URL, _ what: String) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.snapshot.error(
                "Could not delete \(what, privacy: .public) \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
