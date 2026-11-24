import SwiftUI
import NimbleExtensions

extension ProvisionProfileType {
	var title: String {
		switch self {
		case .development: .localized("Development")
		case .enterprise: .localized("Enterprise (In-House)")
		case .adHoc: .localized("Ad Hoc")
		case .distribution: .localized("Distribution")
		case .unknown: .localized("Unknown")
		}
	}

}

extension CertificateRecord {
    var jitBlockReason: String? {
        isPPQLess ? .localized("JIT requires a PPQ certificate. This one uses a PPQLess distribution profile.") : nil
    }
    var ppqBadge: (title: String, icon: String, color: Color) {
        isPPQLess ? (.localized("PPQLess"), "shield.lefthalf.filled", .green)
                  : (.localized("PPQ"), "shield.slash", .orange)
    }
}
