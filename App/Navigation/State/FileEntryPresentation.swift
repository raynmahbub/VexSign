import SwiftUI
import NimbleExtensions

extension IPAFileKind {
	var title: String {
		switch self {
		case .directory:	.localized("Folder")
		case .plist:		.localized("Property List")
		case .text:			.localized("Text")
		case .image:		.localized("Image")
		case .pdf:			.localized("PDF")
		case .executable:	.localized("Executable")
		case .archive:		.localized("Archive")
		case .database:		.localized("Database")
		case .binary:		.localized("Binary")
		}
	}

	var systemImage: String {
		switch self {
		case .directory:	"folder"
		case .plist:		"list.bullet.rectangle"
		case .text:			"doc.text"
		case .image:		"photo"
		case .pdf:			"doc.richtext"
		case .executable:	"gearshape.2"
		case .archive:		"archivebox"
		case .database:		"cylinder.split.1x2"
		case .binary:		"doc"
		}
	}

	var tint: Color {
		switch self {
		case .directory:	.accentColor
		case .plist:		.purple
		case .text:			.blue
		case .image:		.green
		case .pdf:			.red
		case .executable:	.orange
		case .archive:		.brown
		case .database:		.teal
		case .binary:		.gray
		}
	}

}
