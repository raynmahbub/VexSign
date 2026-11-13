//
//  FilesCompressionView.swift
//  VexSign
//
//  Created by VexSign Contributors on 6.05.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct FilesCompressionView: View {
	@AppStorage("VexSign.compressionLevel") private var _compressionLevel: Int = ArchiveCompression.defaultCompression.rawValue
	@AppStorage("VexSign.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("VexSign.useLastExportLocation") private var _useLastExportLocation: Bool = false

	// MARK: Body
    var body: some View {
		NBList(.localized("Files & Compression")) {
			Section {
				Picker(.localized("Compression Level"), systemImage: "archivebox", selection: $_compressionLevel) {
					ForEach(ArchiveCompression.allCases, id: \.rawValue) { level in
						Text(level.label).tag(level.rawValue)
					}
				}
			} footer: {
				Text(.localized("Compression level used when packaging signed apps and exports into IPA archives."))
			}

			Section {
				Toggle(.localized("Show Sheet when Exporting"), systemImage: "square.and.arrow.up", isOn: $_useShareSheet)
			} footer: {
				Text(.localized("Toggling show sheet will present a share sheet after exporting to your files."))
			}

			Section {
				Toggle(.localized("Remember Last Export Location"), systemImage: "clock.arrow.circlepath", isOn: $_useLastExportLocation)
			} footer: {
				Text(.localized("Reopen the Save to Files picker at the last folder you used instead of always starting at the VexSign documents folder."))
			}

			Section {
				NavigationLink(destination: FileManagerView(directory: URL.documentsDirectory, isRoot: true)) {
					Label(.localized("File Manager"), systemImage: "folder.badge.gearshape")
				}
				NavigationLink(destination: ImportFoldersView()) {
					Label(.localized("Import Folders"), systemImage: "folder")
				}
			} footer: {
				Text(.localized("File Manager browses and edits what VexSign stores. Import Folders chooses which folder each kind of import opens in."))
			}
		}
    }
}
