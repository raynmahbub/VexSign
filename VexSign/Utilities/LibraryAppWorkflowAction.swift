// Workflow adaptation from Nyasami/Ksign, revision c14dedc0c9dadb669021cce83435b14f781b8412.
// Original source: LibraryCellView.swift (Feather), created by samara on 11.04.2025.
// GPL-3.0; see LICENSE and docs/THIRD_PARTY_ADAPTATIONS.md. Reworked for VexSign.

import Foundation
import NimbleExtensions

/// KSign's signed/install and unsigned/sign-and-install workflow, adapted to
/// VexSign's existing checked pipelines. See THIRD_PARTY_ADAPTATIONS.md.
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
