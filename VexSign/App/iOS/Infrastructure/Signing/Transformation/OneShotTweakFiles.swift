//
//  OneShotTweakFiles.swift
//  VexSign
//
//  The tweak files a user adds "just for this sign" in the signing sheet.
//
//  They are staged under the app's temporary directory and handed to the signing engine by URL.
//  Two things went wrong with that:
//
//    * the engine *moved* a dylib, framework or bundle out of its staging directory, so the URL
//      was dead as soon as one run had used it. A second attempt in the same sheet, after any
//      failure at all, then stopped in the Customize step with a bare "no such file";
//    * the dead URL was saved with the app's signing settings, so "Re-sign with last settings"
//      and Update All stopped the same way every time, on a signed copy that was perfectly valid.
//
//  The rules that fix it live here, without UIKit, so they can be unit tested: a run works on its
//  own copy of a one-shot file, a missing file is named instead of surfacing as a Cocoa error, and
//  a saved profile keeps the file *names* for the log, never the paths.
//

import Foundation
import NimbleExtensions

enum OneShotTweakFiles {
	/// A file the run was asked to inject is not on disk any more.
	struct Unavailable: LocalizedError, Equatable {
		/// File names only. A staging path is private to this device and useless to the reader.
		let names: [String]

		var errorDescription: String? {
			String.localized(
				"These tweak files are no longer available: %@. Remove them under Tweaks, add them again, then retry.",
				arguments: names.joined(separator: ", ")
			)
		}
	}

	/// File names in the order given, each one once.
	static func names(_ urls: [URL]) -> [String] {
		merged(urls.map(\.lastPathComponent))
	}

	/// Joins name lists, keeping the first occurrence of each name and dropping empty ones.
	static func merged(_ lists: [String]?...) -> [String] {
		var seen = Set<String>()
		var result: [String] = []
		for list in lists {
			for name in list ?? [] where !name.isEmpty && seen.insert(name).inserted {
				result.append(name)
			}
		}
		return result
	}

	/// The files that cannot be read right now.
	static func unavailable(_ urls: [URL], fileManager: FileManager = .default) -> [URL] {
		urls.filter { !fileManager.fileExists(atPath: $0.path) }
	}

	/// Copies every file into `directory` and returns the copies, in the same order.
	///
	/// The signing engine moves what it is given into the app bundle. Handing it copies is what
	/// keeps the files the user staged usable for the next attempt. Each copy gets its own
	/// subdirectory, so two files that share a name cannot overwrite each other and every copy
	/// keeps the name the engine derives the installed file name from.
	///
	/// Nothing is copied unless everything is present: the error names every missing file at
	/// once, so the user does not find them one failed run at a time.
	static func stage(
		_ urls: [URL],
		into directory: URL,
		fileManager: FileManager = .default
	) throws -> [URL] {
		guard !urls.isEmpty else { return [] }

		let missing = unavailable(urls, fileManager: fileManager)
		guard missing.isEmpty else { throw Unavailable(names: names(missing)) }

		var staged: [URL] = []
		staged.reserveCapacity(urls.count)
		for (index, url) in urls.enumerated() {
			let slot = directory.appendingPathComponent("one-shot-\(index)", isDirectory: true)
			try fileManager.createDirectory(at: slot, withIntermediateDirectories: true)
			let copy = slot.appendingPathComponent(url.lastPathComponent)
			try fileManager.copyItem(at: url, to: copy)
			staged.append(copy)
		}
		return staged
	}

	/// What a run that reuses saved settings has to say about files it cannot reuse.
	///
	/// One-shot files are not kept after the sign they were added for, by design: the picker says
	/// so. Replaying the settings without them is correct, and it is still a difference the log
	/// has to state, because for an updated app it means the tweak is not in the new copy.
	static func replayNotices(for names: [String]) -> [String] {
		let names = merged(names)
		guard !names.isEmpty else { return [] }
		return [
			String.localized(
				"The saved settings were captured from a sign that injected one-time tweak files (%@). Those files are not kept, so this run does not inject them. A copy that was signed with them still contains them; a new or updated copy does not.",
				arguments: names.joined(separator: ", ")
			)
		]
	}
}
