import Foundation

/// The event stream's WebSocket, as the stream sees it — so tests can stand a scripted socket in for the server.
protocol EventSocket: Sendable {
    /// The next text frame's bytes. Throws `EventSocketClosed` when the socket ends.
    func receive() async throws -> Data
    /// One ping; returns when the pong arrives.
    func ping() async throws
    func close()
}

/// How a socket ended: the HTTP status of a refused upgrade (401 …), or the close code the server sent.
struct EventSocketClosed: Error, Equatable {
    var httpStatus: Int?
    var closeCode: Int?
    var reason: String
}

/// Opens a socket for an upgrade request.
typealias EventSocketConnector = @Sendable (URLRequest) -> any EventSocket

/// `URLSessionWebSocketTask` behind `EventSocket`.
final class URLSessionEventSocket: EventSocket, @unchecked Sendable {
    // @unchecked: the task is only used through its own thread-safe API.
    private let task: URLSessionWebSocketTask

    init(session: URLSession, request: URLRequest) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    static func connector(session: URLSession) -> EventSocketConnector {
        { URLSessionEventSocket(session: session, request: $0) }
    }

    func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .string(let text): return Data(text.utf8)
            case .data(let data): return data
            @unknown default: return Data()
            }
        } catch {
            throw closed(error)
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    private func closed(_ error: Error) -> EventSocketClosed {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let code = task.closeCode == .invalid ? nil : task.closeCode.rawValue
        let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? error.localizedDescription
        return EventSocketClosed(httpStatus: status == 101 ? nil : status, closeCode: code, reason: reason)
    }
}
