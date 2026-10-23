import Foundation
import OpenAPIRuntime
import QuestCitadelAPI

/// Why a call to the server failed, in the terms the connect card speaks.
enum ServerFailure: Error, Equatable {
    /// 401: the device key was revoked or never existed.
    case rejected
    /// No answer: DNS, TLS, refused, timed out, offline.
    case unreachable(String)
    /// The server answered something else.
    case status(Int)
}

/// Copied from AinkradCitadelPlugin (`Connection/`, `Events/` — as are this folder's ServerAddress, Backoff,
/// DeviceKeyStore, EventFrame, EventSocket and EventStream); keep them in step. Why a copy and not a shared
/// package: Packages/QuestCitadelAPI/Package.swift.
///
/// One server, one device key, one company: the generated client for commands, plus the two requests made outside
/// it — the event stream's upgrade and its HTTP replay, which must decode event by event (`EventFrame`).
struct CitadelServer: Sendable {
    let address: ServerAddress
    let deviceKey: String
    let company: Int64?
    let session: URLSession
    let client: Client

    init(address: ServerAddress, deviceKey: String, company: Int64?, session: URLSession) {
        self.address = address
        self.deviceKey = deviceKey
        self.company = company
        self.session = session
        self.client = CitadelConnection.client(
            server: address.origin, deviceKey: deviceKey, company: company, session: session)
    }

    func scoped(to company: Int64?) -> CitadelServer {
        CitadelServer(address: address, deviceKey: deviceKey, company: company, session: session)
    }

    /// An ephemeral session (no cookies, no cache) that never follows a redirect: a redirect to another host
    /// would carry the bearer key there.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// `GET /api/v1/me` — the key check: who this device is, the server's version, every company the key may
    /// see (the switcher), and the newest event's seq (how far a catch-up has to go).
    func me() async throws(ServerFailure) -> ServerIdentity {
        let output = try await call { try await client.getMe() }
        switch output {
        case .ok(let ok):
            guard let me = try? ok.body.json else { throw .status(200) }
            return ServerIdentity(
                companies: me.companies, version: me.versions.server, latestSeq: me.latestSeq, userID: me.user.id,
                userName: me.user.name)
        case .unauthorized: throw .rejected
        case .undocumented(let status, _): throw .status(status)
        default: throw .status(0)
        }
    }

    /// `GET /api/v1/events?after=` — the HTTP replay, decoded frame by frame so one unknown event type never
    /// fails the page.
    func replay(after seq: Int64, limit: Int = 1000) async throws(ServerFailure) -> EventPage {
        var parts = URLComponents(url: address.origin, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.path = "/api/v1/events"
        parts.queryItems = [
            URLQueryItem(name: "after", value: String(seq)), URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = parts.url else { throw .status(0) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in CitadelConnection.headers(deviceKey: deviceKey, company: company) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw .rejected }
        guard status == 200 else { throw .status(status) }
        do {
            return try EventFrame.decoder.decode(EventPage.self, from: data)
        } catch {
            throw .status(status)
        }
    }

    /// The WebSocket upgrade: the key and company as headers, the resume point as `Last-Event-ID` — never in the
    /// URL. `after == nil` streams only new events.
    func socketRequest(after seq: Int64?) -> URLRequest {
        var request = URLRequest(url: address.eventSocketURL)
        for (name, value) in CitadelConnection.headers(deviceKey: deviceKey, company: company) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let seq { request.setValue(String(seq), forHTTPHeaderField: "Last-Event-ID") }
        return request
    }

    /// Runs a generated call, turning a transport failure into `.unreachable`.
    private func call<T>(_ work: () async throws -> T) async throws(ServerFailure) -> T {
        do {
            return try await work()
        } catch let error as ClientError {
            Log.connection.error("\(error.operationID, privacy: .public) failed: \(error.underlyingError)")
            throw .unreachable(error.underlyingError.localizedDescription)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
    }
}

/// What `GET /me` says about the server.
struct ServerIdentity: Sendable {
    let companies: [Components.Schemas.Company]
    /// The server's version, `0.1.0`.
    let version: String
    let latestSeq: Int64
    /// The person this device acts as (the server's one admin).
    let userID: Int64
    let userName: String
}

/// A page of `GET /events`.
struct EventPage: Decodable, Sendable {
    let items: [EventFrame]
    let nextAfter: Int64?

    enum CodingKeys: String, CodingKey {
        case items
        case nextAfter = "next_after"
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
