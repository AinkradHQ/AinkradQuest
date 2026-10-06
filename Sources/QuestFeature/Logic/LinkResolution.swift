import Foundation

/// What a link means when clicked. Pure: this file imports only Foundation, so
/// every mapping and every refusal is testable without AppKit or a view.
///
/// Three schemes resolve in-process; the rest are honestly inert. Half-working
/// would be worse: opening a repo's folder when the user clicked a `repo` link
/// looks like success and is not what they asked for.
enum LinkResolution {
    enum Route: Equatable {
        /// Show the file in Finder, selected — not launched in whatever app owns
        /// the extension. Quest's links are references, so the usual intent is
        /// to find the thing.
        case reveal(URL)
        case openFolder(URL)
        case web(URL)
        /// Nothing to do, and why — shown to the user rather than failing silently.
        case inert(reason: String)
    }

    static func route(for link: Link) -> Route {
        switch link.scheme {
        case .url:
            // `LinkEditor` lets a user type anything into the identifier field, so
            // a url link can hold arbitrary text. Handing that to the system
            // opener is how an unexpected app launches — accept http(s) only.
            guard let url = URL(string: link.identifier),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                url.host?.isEmpty == false
            else {
                return .inert(reason: "That link is not a web address (http or https).")
            }
            return .web(url)

        case .folder:
            guard let url = absolutePath(link.identifier) else {
                return .inert(reason: "That folder link is not an absolute path.")
            }
            return .openFolder(url)

        case .file:
            guard let url = absolutePath(link.identifier) else {
                return .inert(reason: "That file link is not an absolute path.")
            }
            return .reveal(url)

        case .repo, .branch, .pr, .commit:
            return .inert(
                reason: "Opening \(link.scheme.rawValue) links needs Git Mage, "
                    + "which Quest cannot drive yet.")

        case .unknown:
            return .inert(reason: "Quest does not know how to open this kind of link.")
        }
    }

    /// A path Quest is willing to hand to the system: absolute, non-empty, and
    /// not tilde-relative (expanding `~` here would guess at a home directory
    /// that may not be the one the link was written against).
    private static func absolutePath(_ identifier: String) -> URL? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed)
    }
}
