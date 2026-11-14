import Foundation
import NimbleExtensions

enum WorkspaceGreeting {
    static func title(hour: Int) -> String {
        switch hour {
        case 5..<12: return .localized("Good morning")
        case 12..<18: return .localized("Good afternoon")
        default: return .localized("Good evening")
        }
    }
}
