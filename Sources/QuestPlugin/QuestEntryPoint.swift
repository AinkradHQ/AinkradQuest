import AinkradAppKit
import Foundation
import QuestFeature

/// The bundle's principal class (matches `NSPrincipalClass` in Info.plist).
@objc(QuestEntryPoint)
final class QuestEntryPoint: NSObject, AinkradPluginEntryPoint {
    static func app() -> any AinkradApp.Type { QuestApp.self }
}
