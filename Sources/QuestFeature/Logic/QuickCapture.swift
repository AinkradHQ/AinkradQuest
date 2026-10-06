import Foundation

/// One-line capture syntax: `bug: title #label #label !!`. Deliberately tiny —
/// anything richer belongs in the editor, and a capture box you have to think
/// about is one you stop using.
public enum QuickCapture {
    public struct Parsed: Sendable, Equatable {
        public let title: String
        public let type: WorkItemType
        public let labels: [String]
        public let priority: Priority
    }

    public static func parse(_ raw: String) -> Parsed {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var type = WorkItemType.task

        for candidate in WorkItemType.allCases where candidate != .epic {
            let prefix = "\(candidate.rawValue): "
            if text.lowercased().hasPrefix(prefix) {
                type = candidate
                text = String(text.dropFirst(prefix.count))
                break
            }
        }

        var priority = Priority.none
        if text.hasSuffix("!!") {
            priority = .urgent
            text = String(text.dropLast(2))
        } else if text.hasSuffix("!") {
            priority = .high
            text = String(text.dropLast(1))
        }

        var labels: [String] = []
        let words = text.split(separator: " ")
        var titleWords: [Substring] = []
        for word in words {
            if word.hasPrefix("#"), word.count > 1 {
                labels.append(String(word.dropFirst()))
            } else {
                titleWords.append(word)
            }
        }

        return Parsed(
            title: titleWords.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            type: type, labels: labels, priority: priority)
    }
}
