import Foundation
import NimbleExtensions

// MARK: - LocalizedDescribable

protocol LocalizedDescribable {
	var localizedDescription: String { get }
}

extension LocalizedDescribable where Self: RawRepresentable, RawValue == String {
	var localizedDescription: String {
		let localized = NSLocalizedString(self.rawValue, comment: "")
		return localized == self.rawValue ? self.rawValue : localized
	}
}

extension Options.AppAppearance: LocalizedDescribable {
		var localizedDescription: String {
			switch self {
			case .default: .localized("Default")
			case .light: .localized("Light")
			case .dark: .localized("Dark")
			}
		}
}

extension Options.MinimumAppRequirement: LocalizedDescribable {
		var localizedDescription: String {
			switch self {
			case .default: .localized("Default")
			case .v16: "16.0"
			case .v15: "15.0"
			case .v14: "14.0"
			case .v13: "13.0"
			case .v12: "12.0"
			}
		}
}

extension Options.SigningOption: LocalizedDescribable {
		var localizedDescription: String {
			switch self {
			case .default: .localized("Default")
			case .onlyModify: .localized("Modify")
			}
		}
}

extension Options.PPQProtection: LocalizedDescribable {
		var localizedDescription: String {
			switch self {
			case .disabled: .localized("Disabled")
			case .default: "VexSign"
			case .vex: "Vex"
			}
		}
}

extension Options.InjectPath: LocalizedDescribable {}
extension Options.InjectFolder: LocalizedDescribable {}
