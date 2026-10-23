import QuestCitadelAPI
import Foundation

/// The live event stream with replay (E10.2): catch up over HTTP from the last seq read (`GET /events?after=`),
/// then hold the WebSocket open with `Last-Event-ID` set to that seq, ping it, and on any drop start over after a
/// back-off. HTTP replay is also the fallback: while the socket can't open but HTTP answers, every retry still
/// pulls the missed events and the status says `polling`, not offline.
@MainActor
final class EventStream {
    enum Status: Equatable {
        /// Replaying missed events; `replayed` so far.
        case catchingUp(replayed: Int)
        case live
        /// The socket is down but HTTP replay works; the socket is retried at `retryAt`.
        case polling(attempt: Int, retryAt: Date)
        case offline(attempt: Int, retryAt: Date, reason: String)
        /// 401: the key no longer works. The stream has stopped.
        case rejected
    }

    struct Timing: Sendable {
        var pingEvery: TimeInterval = 20
        var pingTimeout: TimeInterval = 10
        /// Waits out a back-off; tests replace it.
        var wait: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    }

    private let server: CitadelServer
    private let connect: EventSocketConnector
    private let timing: Timing
    private let onStatus: (Status) -> Void
    private let onEvent: (Components.Schemas.Event) -> Void
    private let onCursor: (Int64) -> Void

    /// The last seq read — the resume point.
    private(set) var cursor: Int64?
    /// Events replayed over HTTP since `start`.
    private(set) var replayed = 0
    private(set) var attempt = 0
    private var task: Task<Void, Never>?
    private var waiting: Task<Void, Error>?
    private var socket: (any EventSocket)?
    private var isLive = false

    init(
        server: CitadelServer, cursor: Int64?, connect: @escaping EventSocketConnector, timing: Timing = Timing(),
        onStatus: @escaping (Status) -> Void, onEvent: @escaping (Components.Schemas.Event) -> Void,
        onCursor: @escaping (Int64) -> Void
    ) {
        self.server = server
        self.cursor = cursor
        self.connect = connect
        self.timing = timing
        self.onStatus = onStatus
        self.onEvent = onEvent
        self.onCursor = onCursor
    }

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        waiting?.cancel()
        socket?.close()
        socket = nil
    }

    /// "Retry now": skip the rest of the back-off and start the count again.
    func retryNow() {
        attempt = 0
        waiting?.cancel()
    }

    private func run() async {
        while !Task.isCancelled {
            isLive = false
            var httpWorked = false
            do {
                if cursor != nil {
                    try await catchUp()
                    httpWorked = true
                }
                try await hold(connect(server.socketRequest(after: cursor)))
            } catch let failure as ServerFailure where failure == .rejected {
                return stopRejected()
            } catch let closed as EventSocketClosed where closed.httpStatus == 401 {
                return stopRejected()
            } catch let closed as EventSocketClosed where closed.closeCode == 1013 {
                // Fell behind: the server closed us; resume from the last seq read, at once.
                Log.events.info("stream closed as too slow; resuming after \(self.cursor ?? 0)")
                continue
            } catch {
                guard !Task.isCancelled else { return }
                attempt += 1
                let retryAt = Date().addingTimeInterval(Backoff.delay(attempt: attempt))
                onStatus(
                    httpWorked
                        ? .polling(attempt: attempt, retryAt: retryAt)
                        : .offline(attempt: attempt, retryAt: retryAt, reason: Self.describe(error)))
                let wait = timing.wait
                let delay = Backoff.delay(attempt: attempt)
                waiting = Task { try await wait(delay) }
                _ = try? await waiting?.value
                waiting = nil
            }
        }
    }

    private func stopRejected() {
        socket?.close()
        socket = nil
        task = nil
        onStatus(.rejected)
    }

    /// Pages through `GET /events?after=` until the server has nothing newer.
    private func catchUp() async throws(ServerFailure) {
        while let after = cursor {
            let page = try await server.replay(after: after)
            for frame in page.items { deliver(frame) }
            replayed += page.items.count
            guard page.nextAfter != nil, !page.items.isEmpty else { return }
            onStatus(.catchingUp(replayed: replayed))
        }
    }

    /// Reads the socket and pings it until either fails.
    private func hold(_ socket: any EventSocket) async throws {
        self.socket = socket
        let timing = timing
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.read(socket) }
            group.addTask { try await self.keepAlive(socket, timing: timing) }
            defer {
                socket.close()
                group.cancelAll()
            }
            try await group.next()
        }
    }

    private func read(_ socket: any EventSocket) async throws {
        while true {
            let data = try await socket.receive()
            guard let frame = try? EventFrame.decode(data) else {
                // Not even a seq: nothing to resume from, so skip it like an unknown event.
                Log.events.error("skipped a frame that is not an event (\(data.count) bytes)")
                continue
            }
            markLive()
            deliver(frame)
        }
    }

    private func keepAlive(_ socket: any EventSocket, timing: Timing) async throws {
        while true {
            try await Self.ping(socket, timeout: timing.pingTimeout)
            markLive()
            try await Task.sleep(for: .seconds(timing.pingEvery))
        }
    }

    private static func ping(_ socket: any EventSocket, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await socket.ping()
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return false
            }
            defer { group.cancelAll() }
            guard try await group.next() == true else {
                throw EventSocketClosed(reason: "no answer to a ping in \(Int(timeout)) s")
            }
        }
    }

    private func markLive() {
        guard !isLive else { return }
        isLive = true
        attempt = 0
        onStatus(.live)
    }

    private func deliver(_ frame: EventFrame) {
        if let cursor, frame.seq <= cursor { return }
        cursor = frame.seq
        onCursor(frame.seq)
        if let event = frame.event {
            onEvent(event)
        } else {
            Log.events.info("skipped event \(frame.seq): a type this plugin does not know")
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ServerFailure.unreachable(let reason): reason
        case ServerFailure.status(let status): "the server answered \(status)"
        case let closed as EventSocketClosed: closed.httpStatus.map { "the server answered \($0)" } ?? closed.reason
        default: error.localizedDescription
        }
    }
}
