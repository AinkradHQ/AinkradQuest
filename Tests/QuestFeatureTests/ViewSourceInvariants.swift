import Foundation

/// Reads `Sources/QuestFeature/Views` as text so the suite next door can assert
/// things about the view tree that a unit test cannot observe by running it.
///
/// Why text and not behaviour: the M5 migration shipped six defects of the same
/// class — a view mounted, unmounted, or resolved in the wrong place — and every
/// one compiled and passed the whole suite. Hosting the views in an
/// `NSHostingView` was measured and does not help: SwiftUI collapses to a single
/// `NSView`, and it publishes no accessibility tree unless a real assistive
/// client is attached, so there is nothing to search and no button to press.
///
/// So this is a tripwire, not a discovery tool. It cannot find a *new* trap; it
/// can only stop a known one from coming back — which is exactly the failure
/// that happened, when a fix in Task 12 was never swept back over the files
/// migrated in Task 8.
enum ViewSource {
    /// A file with its comments removed, so an invariant never trips on prose.
    /// The comments in `Views/` discuss the very traps being asserted — five
    /// files mention `@Environment(\.dismiss)` purely to explain why they no
    /// longer use it.
    struct File {
        let name: String
        /// 1-based line number paired with the code on it, comments stripped.
        let lines: [(number: Int, code: String)]

        func contains(_ needle: String) -> Bool {
            lines.contains { $0.code.contains(needle) }
        }

        func lineNumbers(containing needle: String) -> [Int] {
            lines.filter { $0.code.contains(needle) }.map(\.number)
        }
    }

    /// Derived from this file's own path rather than a working directory: the
    /// test runner's cwd is not the repo, and a wrong path here would silently
    /// scan nothing and pass every invariant.
    static var viewsDirectory: URL {
        URL(fileURLWithPath: #filePath)  // …/Tests/QuestFeatureTests/ThisFile.swift
            .deletingLastPathComponent()  // …/Tests/QuestFeatureTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/QuestFeature/Views")
    }

    static func load() throws -> [File] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: viewsDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { name in
            let text = try String(
                contentsOf: viewsDirectory.appendingPathComponent(name),
                encoding: .utf8)
            let lines = text.components(separatedBy: .newlines).enumerated().map {
                (number: $0.offset + 1, code: stripComment(from: $0.element))
            }
            return File(name: name, lines: lines)
        }
    }

    /// Drops a `//` comment, but only when the slashes are outside a string
    /// literal — `"https://…"` appears in this codebase and must survive.
    static func stripComment(from line: String) -> String {
        var inString = false
        var previous: Character?
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" { inString.toggle() }
            if !inString, character == "/", line.index(after: index) < line.endIndex,
                line[line.index(after: index)] == "/"
            {
                break
            }
            result.append(character)
            previous = character
            index = line.index(after: index)
        }
        return result
    }

    // MARK: - Block extraction

    /// The lines of the `{ … }` body that follows the first occurrence of
    /// `opener` on or after `start`, found by brace balance.
    ///
    /// The block is considered open only once a line ENDS with unclosed braces.
    /// Checking mid-line would end it immediately on
    /// `.ainkradModal(isPresented: Binding(get: { … },` — whose braces open and
    /// close within the line — and return a one-line block containing no
    /// content, which is how the first version of this scanner passed every
    /// modal in the codebase while asserting nothing.
    static func block(in file: File, from start: Int) -> [(number: Int, code: String)] {
        var depth = 0
        var started = false
        var collected: [(number: Int, code: String)] = []
        for line in file.lines where line.number >= start {
            for character in line.code {
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1 }
            }
            collected.append(line)
            if depth > 0 { started = true }
            if started && depth <= 0 { break }
        }
        return collected
    }

    /// Splits a file into its top-level `struct`/`final class` declarations, so
    /// an invariant can be scoped to ONE type. File scope is too coarse:
    /// `QuestShell.swift` deliberately holds both the wrapper that applies the
    /// toast host and the content view that reads it — the fix for the bug,
    /// which a file-level check would report as the bug.
    static func types(in file: File) -> [(name: String, lines: [(number: Int, code: String)])] {
        var result: [(name: String, lines: [(number: Int, code: String)])] = []
        for line in file.lines {
            if let name = declaredTypeName(on: line.code) {
                result.append((name: name, lines: [line]))
            } else if !result.isEmpty {
                result[result.count - 1].lines.append(line)
            }
        }
        return result
    }

    /// Matches a top-level declaration — no leading whitespace, so a nested
    /// helper type stays part of its enclosing type's block.
    static func declaredTypeName(on code: String) -> String? {
        for keyword in ["struct ", "final class ", "class ", "enum ", "extension "] {
            let prefixes = ["", "public ", "private ", "internal ", "fileprivate "]
            for prefix in prefixes where code.hasPrefix(prefix + keyword) {
                let rest = code.dropFirst((prefix + keyword).count)
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                return name.isEmpty ? nil : String(name)
            }
        }
        return nil
    }
}
