//
//  FileExporter.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation

enum FileExporter {
	/// A file shares as-is; a directory bundle (e.g. `.framework`) has to be zipped first.
	static func shareableURL(for source: URL) -> URL? {
		let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
		guard isDirectory else { return source }

		let exportDir = FileManager.default.uniqueTemporaryDirectory("FileExport")
		let zipURL = exportDir.appendingPathComponent("\(source.lastPathComponent).zip")
		do {
			try FileManager.default.createDirectoryIfNeeded(at: exportDir)
			try ArchiveEngine.zipDirectory(source, to: zipURL)
			return zipURL
		} catch {
			return nil
		}
	}
}
