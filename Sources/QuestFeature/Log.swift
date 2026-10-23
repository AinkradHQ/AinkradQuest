import AinkradAppKit
import os

/// Quest's log areas, on the shared Ainkrad subsystem (`AinkradLog`), so one
/// Console filter covers the host and every plugin.
enum Log {
    static let snapshot = AinkradLog.logger(app: "quest", area: "snapshot")
    /// Citadel server mode (E12). Nothing here ever logs a device key.
    static let connection = AinkradLog.logger(app: "quest", area: "connection")
    static let events = AinkradLog.logger(app: "quest", area: "events")
}
