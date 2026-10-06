import AinkradAppKit
import os

/// Quest's log areas, on the shared Ainkrad subsystem (`AinkradLog`), so one
/// Console filter covers the host and every plugin.
enum Log {
    static let snapshot = AinkradLog.logger(app: "quest", area: "snapshot")
}
