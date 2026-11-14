import Foundation

enum InstallMethodKind: String, CaseIterable, Identifiable, Sendable {
	case server
	case idevice
	case liveContainer
	case export
	case trollstore

	var id: String { rawValue }

	/// Preserve the existing OTA/IDevice preferences. Unknown values must not fall back to OTA.
	static func selected(forStoredValue value: Int) -> Self? {
		switch value {
		case 0: return .server
		case 1: return .idevice
		case 2: return .liveContainer
		default: return nil
		}
	}


}

enum InstallReadiness: Equatable, Sendable {
	/// Everything this method needs is present.
	case ready
	/// Present, but something specific is missing; the string says what to do about it.
	case missing(String)
	/// The method cannot work on this device at all (TrollStore is not installed).
	case unavailable(String)
	/// The app cannot check this from inside the sandbox; the string says where to look.
	case unknown(String)
}

struct InstallMethodReport: Identifiable, Equatable, Sendable {
	let method: InstallMethodKind
	let readiness: InstallReadiness
	var id: String { method.rawValue }
}
