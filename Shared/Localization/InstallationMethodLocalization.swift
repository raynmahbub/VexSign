import Foundation
import NimbleExtensions

extension InstallMethodKind {
	var title: String {
		switch self {
		case .server:	return .localized("Local HTTPS server")
		case .idevice:	return .localized("idevice (pairing file)")
		case .liveContainer: return .localized("Embedded LiveContainer guest")
		case .export:	return .localized("Export or share the IPA")
		case .trollstore: return .localized("TrollStore")
		}
	}
}
