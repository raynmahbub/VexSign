//
//  ArchiveEngine.swift
//  VexSign
//

import Foundation
import ZIPFoundation

enum ArchiveEngine {
	static func zipDirectory(
		_ directory: URL,
		to destination: URL,
		compression: ArchiveCompression = .defaultCompression,
		shouldKeepParent: Bool = true,
		progress: ((Double) -> Void)? = nil
	) throws {
		var observation: NSKeyValueObservation?
		var reported: Progress?
		if let progress {
			let tracker = Progress(totalUnitCount: 1)
			observation = tracker.observe(\.fractionCompleted, options: [.new]) { tracker, _ in
				progress(tracker.fractionCompleted)
			}
			reported = tracker
		}
		defer { observation?.invalidate() }

		try FileManager.default.zipItem(
			at: directory,
			to: destination,
			shouldKeepParent: shouldKeepParent,
			compressionMethod: compression.compressionMethod,
			progress: reported
		)
	}

	static func zipItems(
		_ sources: [URL],
		to destination: URL,
		compression: ArchiveCompression = .defaultCompression,
		progress: ((Double) -> Void)? = nil
	) throws {
		if sources.count == 1, let only = sources.first {
			// Same shape as the multi-source path below: the archive contains the
			// items, not the directory that happens to hold them. Keeping the
			// parent here meant a one-item tweak export gained a directory level
			// that a two-item export did not.
			try zipDirectory(only, to: destination, compression: compression,
			                 shouldKeepParent: false, progress: progress)
			return
		}

		let fm = FileManager.default
		let staging = fm.uniqueTemporaryDirectory("ArchiveStage")
		try fm.createDirectory(at: staging, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: staging) } // try? ok: temporary staging directory cleanup is best-effort

		for source in sources {
			let staged = staging.appendingPathComponent(source.lastPathComponent)
			do {
				try fm.linkItem(at: source, to: staged)
			} catch {
				try fm.copyItem(at: source, to: staged)
			}
		}

		var observation: NSKeyValueObservation?
		var reported: Progress?
		if let progress {
			let tracker = Progress(totalUnitCount: 1)
			observation = tracker.observe(\.fractionCompleted, options: [.new]) { tracker, _ in
				progress(tracker.fractionCompleted)
			}
			reported = tracker
		}
		defer { observation?.invalidate() }

		try fm.zipItem(
			at: staging,
			to: destination,
			shouldKeepParent: false,
			compressionMethod: compression.compressionMethod,
			progress: reported
		)
	}
}
