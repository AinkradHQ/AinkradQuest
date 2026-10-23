import AinkradAppKit
import Foundation

/// The device key, kept ONLY in the host's secret store (Keychain) — never in documents, UserDefaults or a file —
/// one per server origin, so a second server never receives the first one's key.
@MainActor
struct DeviceKeyStore {
    let secrets: PluginSecretStore

    static func secretKey(for server: ServerAddress) -> String { "device-key \(server.origin.absoluteString)" }

    func key(for server: ServerAddress) -> String? {
        secrets.secret(forKey: Self.secretKey(for: server)).flatMap { $0.isEmpty ? nil : $0 }
    }

    func setKey(_ key: String?, for server: ServerAddress) {
        secrets.setSecret(key, forKey: Self.secretKey(for: server))
    }

    /// The field's text for a key: its prefix up to the last `_`, dots, and the last 4 characters
    /// (`ck_dev_••••7Q2m`). Never more of the key than that.
    static func masked(_ key: String, dots: Int = 4) -> String {
        let tail = String(key.suffix(4))
        let body = key.dropLast(4)
        let prefix = body.lastIndex(of: "_").map { String(body[...$0]) } ?? ""
        return prefix + String(repeating: "•", count: dots) + tail
    }
}
