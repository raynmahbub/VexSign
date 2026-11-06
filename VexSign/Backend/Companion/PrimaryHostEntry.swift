import Foundation
import SwiftUI

/// Stable C ABI used by the pinned host bootstrap. Unlike a container guest,
/// this runs against the actual main bundle, home, defaults and Keychain scope.
/// The authorized installer still has to sign the host and every nested image.
@_cdecl("VexSignPrimaryMain")
@MainActor
public func VexSignPrimaryMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let metadata = Bundle.main.infoDictionary ?? [:]
    guard metadata["VexSignPrimaryHost"] as? Bool == true,
          metadata["VexSignEmbeddedGuest"] as? Bool != true else { return 78 }
    VexSignApp.main()
    return 0
}
