// GPL-3.0; see LICENSE.

import Foundation
import NimbleExtensions

/// The signed/install and unsigned/sign-and-install workflow, wired to VexSign's
/// existing checked pipelines.
enum LibraryAppWorkflowAction: Hashable {
    case install, resign, signAndInstall

    static func actions(isSigned: Bool, containerized: Bool = false) -> [Self] {
        if isSigned { return [.install, .resign] }
        // The host signs a guest during its explicit import flow. Direct OTA/IDevice installs
        // retain the certificate-signing requirement for an unsigned library import.
        return containerized ? [.install, .signAndInstall] : [.signAndInstall]
    }

    static func signingOptions(from base: Options, installAfterSigning: Bool) -> Options {
        var options = base
        if installAfterSigning { options.post_installAppAfterSigned = true }
        return options
    }

    var title: String {
        switch self {
        case .install: return .localized("Install")
        case .resign: return .localized("Re-sign")
        case .signAndInstall: return .localized("Sign & Install")
        }
    }

    var systemImage: String {
        self == .install ? "square.and.arrow.down" : "signature"
    }
}
