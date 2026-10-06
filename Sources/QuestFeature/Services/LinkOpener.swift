import AppKit
import Foundation

public enum LinkOpenError: Error, Equatable {
    case missingTarget(path: String)
    /// The target exists but is not a plain folder — a file, or a bundle such as
    /// a `.app`, which the system opener would LAUNCH rather than show.
    case notAFolder(path: String)
    /// A URL reached `openWeb` that is not http(s).
    case notAWebAddress(url: String)

    public var message: String {
        switch self {
        case .missingTarget(let path): "Nothing exists at \(path) any more."
        case .notAFolder(let path): "\(path) is not a folder, so Quest will not open it."
        case .notAWebAddress(let url): "\(url) is not a web address (http or https)."
        }
    }
}

/// The side-effecting edge of link opening, behind a protocol so the click path
/// is testable without opening a real Finder window.
/// ## Requirements on conformances
///
/// Swift cannot express these in the type system — a protocol declares
/// signatures, not preconditions — so they are stated here and every
/// conformance must honour them; `LinkOpening.open` relies on them:
///
/// - `reveal` MUST verify its target exists and throw `LinkOpenError` rather
///   than silently doing nothing. A link outlives the thing it points at.
/// - `openFolder` MUST verify its target exists AND is a plain directory, and
///   MUST refuse a bundle (`.app` and friends). The system opener LAUNCHES an
///   app bundle and opens a document in its owning app, so an unchecked
///   `openFolder` turns an agent-written identifier into a one-click launch.
/// - `openWeb` MUST re-check that the URL is http(s) and throw otherwise.
///   `LinkResolution` already decides this; repeating it here is deliberate
///   defense in depth — that is a pure decision, this is the irreversible act.
@MainActor public protocol LinkOpener {
    func reveal(_ url: URL) throws
    func openFolder(_ url: URL) throws
    func openWeb(_ url: URL) throws
}

/// The production opener.
///
/// This works without any security-scoped access because the Ainkrad host
/// carries no `com.apple.security.app-sandbox` entitlement (only
/// `com.apple.security.cs.disable-library-validation`). That is a deliberate,
/// recorded trade — see the M4 design. If Ainkrad ever adopts the sandbox,
/// opening files and folders outside a granted root will start failing, and
/// per-attachment security-scoped bookmarks (removed in M3 because nothing read
/// them) come back, with this type as the reader that justifies them.
@MainActor public struct WorkspaceLinkOpener: LinkOpener {
    public init() {}

    public func reveal(_ url: URL) throws {
        try requireExists(url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openFolder(_ url: URL) throws {
        try Self.validateFolder(url)
        NSWorkspace.shared.open(url)
    }

    public func openWeb(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw LinkOpenError.notAWebAddress(url: url.absoluteString)
        }
        NSWorkspace.shared.open(url)
    }

    /// Extensions the system treats as launchable/openable packages rather than
    /// plain folders. All of these ARE directories on disk, so an `isDirectory`
    /// check alone is not enough.
    private static let bundleExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc",
        "prefpane", "qlgenerator", "saver", "service", "workflow", "pkg",
        "mpkg", "dmg", "xcodeproj", "xcworkspace", "playground", "rtfd",
        "scptd", "download", "photoslibrary", "musiclibrary", "tvlibrary",
        "logicx", "band", "sparsebundle",
    ]

    /// Separated from `openFolder` so the whole refusal decision is testable
    /// without `NSWorkspace` opening a real Finder window.
    ///
    /// `URL(fileURLWithPath:)` does not normalize `..` and `NSWorkspace` follows
    /// symlinks, so `/tmp/../Applications/Calculator.app` reaches the real
    /// bundle. Validation therefore runs on the fully resolved path while the
    /// error names the path the user actually wrote.
    static func validateFolder(_ url: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory)
        else {
            throw LinkOpenError.missingTarget(path: url.path)
        }
        guard isDirectory.boolValue else { throw LinkOpenError.notAFolder(path: url.path) }
        // Refuse, do not quietly reveal instead: the user asked to open a
        // folder, and substituting a different action would hide that the link
        // does not point at one.
        guard !bundleExtensions.contains(resolved.pathExtension.lowercased()) else {
            throw LinkOpenError.notAFolder(path: url.path)
        }
    }

    /// A link outlives the thing it points at: files get moved, volumes get
    /// unmounted. Checking first turns a silent no-op into a message.
    private func requireExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LinkOpenError.missingTarget(path: url.path)
        }
    }
}

/// Routes a link through `LinkResolution` and performs the result.
/// Returns a reason when there was nothing to do, so the caller can show it.
@MainActor public enum LinkOpening {
    @discardableResult
    public static func open(_ link: Link, using opener: some LinkOpener) throws -> String? {
        switch LinkResolution.route(for: link) {
        case .reveal(let url):
            try opener.reveal(url)
            return nil
        case .openFolder(let url):
            try opener.openFolder(url)
            return nil
        case .web(let url):
            try opener.openWeb(url)
            return nil
        case .inert(let reason): return reason
        }
    }
}
