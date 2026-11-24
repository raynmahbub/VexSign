import Foundation

struct AdditionalProfileRecord: Equatable, Identifiable {
		let url: URL
		/// The profile's `application-identifier`, e.g. `TEAMID.com.example.app.widget`.
		let pattern: String
		let name: String
		let expirationDate: Date

		var id: String { url.path }
		var isExpired: Bool { expirationDate < Date() }
	}
