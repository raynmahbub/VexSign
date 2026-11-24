//
//  WebManagerTransferLimits.swift
//  VexSign
//
//  What the Web Manager will accept, and what it will refuse before it fills the device.
//
//  `ServerApplicationFactory` sets `defaultMaxBodySize` (32 MB), but that caps *collected*
//  bodies. Every upload route here streams — `POST /upload/:name`, WebDAV `PUT` and
//  `POST /api/sign` all drain the body straight to disk so a 2 GB IPA never becomes a 2 GB
//  allocation — and a streamed body does not consult that cap at all. Without the numbers
//  below, "how much may a client write" had no answer: the app container grew until the
//  volume was full, and then the database, the library store and every pending download
//  failed too, for a reason that had nothing to do with them.
//
//  Both checks are pure functions so the arithmetic is testable without a socket, a
//  simulator certificate or a nearly-full device.
//

import Foundation

enum WebManagerTransferLimits {
	/// The inbox (browser uploads and WebDAV): an IPA, a `.deb`, a `.zip` of tweaks.
	static let inbox: Int = 512 * 1024 * 1024

	/// `/api/sign` streams an IPA in and a signed IPA out, so it gets the larger bound.
	static let signing: Int = 2 * 1024 * 1024 * 1024

	/// How much may be written between two free-space readings. A streamed body has no
	/// trustworthy size up front (a chunked request may declare none), so the ceiling alone
	/// cannot prevent a device from filling mid-transfer; check the volume as the file grows.
	static let spaceCheckInterval: Int = 8 * 1024 * 1024

	/// Space that must remain free after an accepted upload. Below this the device has
	/// more pressing problems than a transfer, and refusing early is friendlier than
	/// letting the write fail halfway through an install.
	static let freeSpaceReserve: Int64 = 256 * 1024 * 1024

	static let tooLargeMessage = "That file is larger than this server accepts."
	static let noSpaceMessage = "Not enough free space on this device to receive that file."

	/// Whether one more buffer may be written: the cap applies to the *finished* file, and
	/// a exactly-at-the-limit upload is accepted (the limit is a ceiling, not a margin).
	static func accepts(current: Int, incoming: Int, limit: Int) -> Bool {
		guard incoming > 0 else { return true }
		guard current >= 0, limit > 0 else { return false }
		// `current + incoming` can overflow on a hostile sequence; compare as differences.
		return incoming <= limit - min(current, limit)
	}

	/// Whether the device can hold `maximumBytes` more data, given the volume's free space.
	///
	/// `freeBytes == nil` means the volume did not report a capacity. Uploads stay allowed
	/// in that case: refusing a transfer because a filesystem would not answer would be a
	/// worse failure than the one this guard exists to prevent.
	static func hasRoom(freeBytes: Int64?, requiredBytes: Int, reserve: Int64 = freeSpaceReserve) -> Bool {
		guard let freeBytes else { return true }
		return freeBytes >= Int64(max(0, requiredBytes)) + max(0, reserve)
	}

	/// Free space on the volume that holds the app container, in bytes, when it is known.
	static func availableBytes() -> Int64? {
		let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
		let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) // try? ok: unknown capacity is treated as permissive, not as an upload failure
		return values?.volumeAvailableCapacityForImportantUsage
	}
}
