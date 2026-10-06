import Foundation

enum CredentialError: Error, Equatable, Sendable, LocalizedError {
    /// Which Keychain operation failed, so `message` can name it accurately.
    /// `ConnectionRegistry.removeConnection` composes this into a larger
    /// sentence about a failed DELETE — a `save`-worded message there produced
    /// a self-contradictory "…could not be deleted…: Could not save…".
    enum Operation: Equatable, Sendable {
        case save
        case delete
    }

    case keychain(Operation, OSStatus)

    /// Written to be read by a person, matching `QuestError.message`'s style —
    /// otherwise a Keychain failure reaches the user as Foundation's generic
    /// "The operation couldn't be completed. (QuestFeature.CredentialError
    /// error 0.)", for the single most important failure in the credential
    /// story.
    var message: String {
        switch self {
        case .keychain(let operation, let status):
            let verb = operation == .save ? "save" : "delete"
            return "Could not \(verb) the token in the Keychain (status \(status)). "
                + "Try again, or check Keychain Access for a conflicting entry."
        }
    }

    /// `LocalizedError` conformance routes through the same text, so any call
    /// site that only knows `Error.localizedDescription` still gets it.
    var errorDescription: String? { message }
}

/// The seam that keeps secrets out of documents. Everything above it — the
/// registry, the UI, the future adapters — asks for a secret by ref and never
/// learns where it is kept.
protocol CredentialStore: Sendable {
    func secret(forRef ref: String) -> String?
    /// Passing `nil` deletes the entry. Throws when the underlying store
    /// refused the write: a silently-lost credential looks exactly like a
    /// revoked token later, which is a miserable thing to debug.
    func setSecret(_ secret: String?, forRef ref: String) throws
}
