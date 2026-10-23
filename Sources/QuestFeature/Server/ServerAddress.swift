import Foundation

/// A Citadel server's origin, checked at the boundary: HTTPS only, except plain HTTP to this Mac (loopback) for
/// development. No user info, query or fragment, and no path — the device key must never ride in a URL, and the
/// operations carry their own `/api/v1` paths.
struct ServerAddress: Equatable, Sendable {
    enum Problem: Error, Equatable {
        case empty
        case unreadable
        case plainHTTP(host: String)
        case unsupportedScheme(String)
        case extraParts
    }

    /// `https://host[:port]`, lower-cased, no trailing slash.
    let origin: URL
    let host: String

    /// Accepts what a person types: a bare host gets `https://`, one trailing `/` is dropped.
    init(_ typed: String) throws(Problem) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let parts = URLComponents(string: withScheme), let scheme = parts.scheme?.lowercased(),
            let host = parts.host?.lowercased(), !host.isEmpty
        else { throw .unreadable }
        guard parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty || parts.path == "/"
        else { throw .extraParts }
        switch scheme {
        case "https": break
        case "http": guard Self.isLoopback(host) else { throw .plainHTTP(host: host) }
        default: throw .unsupportedScheme(scheme)
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = parts.port
        guard let url = origin.url else { throw .unreadable }
        self.origin = url
        self.host = host
    }

    /// `localhost`, 127.0.0.0/8 and `::1`: traffic that never leaves this Mac.
    static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare == "::1" || bare.hasPrefix("127.")
    }

    /// The event stream's WebSocket URL: `wss` for `https`, `ws` for loopback `http`.
    var eventSocketURL: URL {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.scheme = origin.scheme == "https" ? "wss" : "ws"
        parts.path = "/api/v1/events/ws"
        return parts.url ?? origin
    }

    /// What the connect card says about a typed address it refuses.
    static func message(for problem: Problem) -> String {
        switch problem {
        case .empty: "Enter the server's address."
        case .unreadable: "That isn't a server address."
        case .plainHTTP(let host): "\(host) must use https. Plain http is only for a server on this Mac."
        case .unsupportedScheme(let scheme): "\(scheme):// isn't supported — use https."
        case .extraParts: "Use the server's address only: no path, query or user name."
        }
    }
}
