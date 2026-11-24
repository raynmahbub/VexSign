import Foundation
import NimbleExtensions

enum LibraryAttentionReason: Equatable {
    case revoked, expired, expiringSoon, updateAvailable

    static func evaluate(isSigned: Bool, expiry: Date?, revoked: Bool, hasUpdate: Bool, now: Date = Date()) -> Self? {
        if isSigned && revoked { return .revoked }
        if isSigned, let expiry {
            if expiry <= now { return .expired }
            if expiry.timeIntervalSince(now) <= 7 * 86_400 { return .expiringSoon }
        }
        if hasUpdate { return .updateAvailable }
        // Missing evidence is not a failure. Imported apps need not be signed yet.
        return nil
    }
}
