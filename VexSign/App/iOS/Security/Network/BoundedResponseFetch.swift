//
//  BoundedResponseFetch.swift
//  VexSign
//
//  Metadata endpoints — GitHub's API, a certificate host, the App Store lookup,
//  the IPSW catalogue, the user's DNS rules file — are not this app's own servers.
//  Each caller already knows how much of a body it is willing to parse, but
//  `URLSession.data(for:)` allocates the whole body before that check can run, so a
//  hostile or broken endpoint decides the app's peak memory instead of the caller.
//
//  `NBFetchService.fetchRaw` solved the same problem for repository feeds by
//  streaming to disk and stopping at the cap. This is the same contract for the
//  callers that keep their own `URLRequest` (headers, timeouts) or an injected
//  session: stream, stop, then hand back the `Data` + `URLResponse` pair they
//  already expect.
//

import Foundation

enum BoundedResponseFetch {
	enum Failure: Error, Equatable {
		/// The body passed the caller's cap and the transfer was stopped.
		case tooLarge(limitBytes: Int64)
	}

	/// Fetch `request`, refusing to hold more than `maximumBytes` of the body.
	///
	/// The transfer is cancelled as soon as the cap is crossed, so the limit bounds
	/// both the bytes on disk and the `Data` handed back — not just the check after
	/// the fact. Redirects keep their default handling; callers that care about the
	/// final origin already inspect `URLResponse.url`.
	static func fetch(
		_ request: URLRequest,
		maximumBytes: Int64,
		session: URLSession = .shared
	) async throws -> (Data, URLResponse) {
		precondition(maximumBytes > 0, "a bounded fetch needs a positive cap")

		// The existing download delegate is what makes the cap real: it cancels the
		// task from `didWriteData` once the limit is crossed, mid-stream.
		let limiter = PackageDownloadRedirectDelegate(maximumBytes: maximumBytes)
		let fileURL: URL
		let response: URLResponse
		do {
			(fileURL, response) = try await session.download(for: request, delegate: limiter)
		} catch {
			if limiter.didExceedLimit {
				throw Failure.tooLarge(limitBytes: maximumBytes)
			}
			throw error
		}

		let data: Data
		do {
			let size = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
			guard size <= maximumBytes else {
				throw Failure.tooLarge(limitBytes: maximumBytes)
			}
			data = try Data(contentsOf: fileURL)
		} catch {
			remove(fileURL)
			throw error
		}
		remove(fileURL)
		return (data, response)
	}

	/// A response that arrived in full is consumed by its caller; the staging file is
	/// not needed either way, and leaving it behind would accumulate one file per poll.
	private static func remove(_ url: URL) {
		do {
			try FileManager.default.removeItem(at: url)
		} catch {
			SubsystemDiagnosticsLog.warn(
				"Could not remove a consumed response body: \(error.localizedDescription)",
				subsystem: .network
			)
		}
	}
}
