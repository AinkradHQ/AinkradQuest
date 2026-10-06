import Foundation

/// Suggests folders whose name matches a project's, one level under a granted
/// root. Deliberately dumb: a case-insensitive containment match, offered as a
/// suggestion the user edits. Fuzzy matching was rejected — a wrong suggestion
/// silently accepted is worse than no suggestion.
enum FolderMatch {
    static func candidates(for projectName: String, in root: URL) -> [URL] {
        let needle = projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { $0.lastPathComponent.lowercased().contains(needle) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A directory containing `.git` is a repo; anything else is a plain folder.
    static func linkKind(for url: URL) -> LinkScheme {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
            ? .repo : .folder
    }
}
