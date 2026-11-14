import Foundation
import NimbleExtensions

extension AnalyticsMetric {
    var title: String {
        switch self {
        case .appsSigned: return .localized("Apps Signed")
        case .appsInstalled: return .localized("Apps Installed")
        case .certificatesAdded: return .localized("Certificates Added")
        case .tweaksInjected: return .localized("Tweaks Injected")
        case .repositoriesAdded: return .localized("Repositories Added")
        }
    }
}
