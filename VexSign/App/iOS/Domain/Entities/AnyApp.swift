import Foundation

struct AnyApp: Identifiable {
	let base: AppInfoPresentable
	var archive: Bool = false
    var installAfterSigning: Bool = false

	var id: String {
		base.recordID ?? "\(base.isSigned):\(base.uuid ?? "unavailable")"
	}
}
