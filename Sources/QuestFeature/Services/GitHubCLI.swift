import Foundation

/// Real conformance, shelling out to the `gh` binary. Kept intentionally thin —
/// all decision logic (what counts as logged-out, how scopes split, what
/// `id` an account gets) lives in `GitHubAccountParsing.parseAccounts`, which
/// is pure and unit-tested. This type's only job is finding the binary and
/// running two commands.
public final class GitHubCLI: GitHubAccountSource, Sendable {
    /// Homebrew (Apple Silicon and Intel default prefixes) and the common
    /// system locations. Checked in order before falling back to `PATH`,
    /// because `Process` does not consult the shell's PATH resolution on its
    /// own the way a shell invocation would.
    private static let knownPaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ]

    /// Generous for a local CLI call (Keychain/config reads normally complete
    /// in milliseconds), but short enough that a hang — a locked Keychain, an
    /// MDM hook, an expired credential prompting interactive re-auth, a
    /// first-run telemetry prompt — does not freeze the UI for long. 5s.
    private static let defaultTimeout: TimeInterval = 5

    private let binaryPath: String

    public init() throws {
        self.binaryPath = try Self.locateBinary()
    }

    private static func locateBinary() throws -> String {
        let fileManager = FileManager.default
        for path in knownPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to `PATH`, in case `gh` was installed somewhere else
        // (e.g. via mise/asdf, a custom prefix, or a non-Homebrew package
        // manager). `/usr/bin/which` is itself a fixed, always-present path,
        // so this does not reintroduce the "assume a path" problem.
        if let found = try? runProcess(executable: "/usr/bin/which", arguments: ["gh"]),
            found.exitCode == 0
        {
            let path = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw GitHubCLIError.cliNotInstalled
    }

    public func accounts() throws -> [GitHubAccount] {
        let result = try Self.runProcess(executable: binaryPath, arguments: ["auth", "status", "--json", "hosts"])
        guard result.exitCode == 0 else {
            throw GitHubCLIError.commandFailed(stderr: Self.excerpt(result.stderr))
        }
        return try GitHubAccountParsing.parseAccounts(Data(result.stdout.utf8))
    }

    public func token(for account: GitHubAccount) throws -> String {
        let result = try Self.runProcess(
            executable: binaryPath,
            arguments: ["auth", "token", "--user", account.login, "--hostname", account.host]
        )
        guard result.exitCode == 0 else {
            // Never let a token leak into an error message — stderr from
            // `gh auth token` does not carry the secret, only diagnostics.
            throw GitHubCLIError.commandFailed(stderr: Self.excerpt(result.stderr))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func excerpt(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    /// Internal (not private) so `GitHubCLITests` can drive it directly with
    /// a stand-in binary (e.g. `/bin/sleep`) and a short timeout, to test the
    /// timeout path deterministically without depending on a real slow `gh`.
    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Reads both pipes concurrently on background queues rather than
    /// sequentially. Reading stdout to EOF before touching stderr deadlocks
    /// if the child fills the stderr pipe's buffer while blocked writing to
    /// it — the parent would never get around to draining stderr. Starting
    /// both reads before `waitUntilExit` avoids that classic pipe deadlock.
    ///
    /// Bounded by `timeout`: on expiry the process is terminated and a
    /// distinct `.timedOut` error is thrown, rather than looking like a
    /// normal command failure — a hang has a different remedy (the user runs
    /// the command by hand to see what it's stuck on) than an exit-code
    /// failure does.
    static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let readGroup = DispatchGroup()
        // Each is written once on its read queue and read only after
        // `readGroup.wait`; the group's leave/wait orders that write before
        // the read, which the compiler cannot see through `DispatchGroup`.
        nonisolated(unsafe) var stdoutData = Data()
        nonisolated(unsafe) var stderrData = Data()

        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }

        try process.run()

        if exitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // Give the process a moment to actually die and close its pipe
            // ends so the background reads unblock; this is a bounded grace
            // period, not an open-ended wait.
            _ = exitSemaphore.wait(timeout: .now() + 1)
            _ = readGroup.wait(timeout: .now() + 1)
            throw GitHubCLIError.timedOut
        }

        // Process has exited; the pipe write ends are now closed, so these
        // background reads are guaranteed to reach EOF promptly.
        readGroup.wait()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
