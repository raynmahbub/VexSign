//
//  SourceFeedLoader.swift
//  VexSign
//
//  Fetch + decode for one source, off the main actor.
//
//  `SourcesViewModel` used to fetch a batch in a task group and then decode every payload *after*
//  the group had returned — inside a `@MainActor` method, i.e. on the thread that draws the screen.
//  A five-megabyte repository is a few hundred milliseconds of JSON parsing in the middle of a
//  scroll. Both halves now happen here, in a value type that carries no isolation, and only the
//  finished result crosses back to the view model to be published.
//

import Foundation
import AltSourceKit
import NimbleJSON
import NimbleExtensions
import OSLog
import os

// MARK: - Outcome

/// What one source produced, in a form that can cross back to the main actor.
enum SourceFeedOutcome: Sendable {
	/// Decoded. The raw payload rides along because the snapshot cache stores bytes, not models.
	case decoded(ASRepository, payload: Data)
	/// Fetched, but not a repository this build can read. The payload is kept so it can still be
	/// cached — a source that decodes after an app update is not re-downloaded.
	case invalid(payload: Data)
	/// Not fetched: offline, HTTP error, rate limited, or an empty body.
	case failed(message: String, rateLimited: Bool)
}

struct SourceFeedResult: Sendable {
	let identifier: String
	let outcome: SourceFeedOutcome
}

// MARK: - Loader

/// Everything one source needs: the network call and the decode, both non-isolated.
struct SourceFeedLoader: Sendable {
	/// The network call, injected so a test can hand back a synthetic payload.
	typealias Fetcher = @Sendable (URL, [String: String]) async -> Swift.Result<Data, Error>

	let fetcher: Fetcher
	/// Called with `Thread.isMainThread` immediately before a payload is decoded. Production leaves
	/// this nil; the test points it at a recorder, which is how "the decode is not on the main
	/// thread" is proven instead of asserted in a comment.
	let willDecode: (@Sendable (Bool) -> Void)?

	init(fetcher: @escaping Fetcher, willDecode: (@Sendable (Bool) -> Void)? = nil) {
		self.fetcher = fetcher
		self.willDecode = willDecode
	}

	/// Fetches and decodes one source. Call it from a task, never from the main actor.
	func load(url: URL, headers: [String: String], identifier: String) async -> SourceFeedResult {
		let signpost = SourceFeedSignposts.loader.beginInterval(
			"source",
			id: SourceFeedSignposts.loader.makeSignpostID()
		)
		defer { SourceFeedSignposts.loader.endInterval("source", signpost) }

		// GitHub repository URLs are virtual sources: fetch the latest release from
		// the public API, then adapt its single IPA asset to the normal feed model.
		let isGitHubReleaseSource = GitHubReleaseSource.isGitHubRepositoryURL(url)
		let requestURL = GitHubReleaseSource.apiURL(for: url) ?? url
		// Do not forward credentials meant for a private repository host to GitHub's
		// public API endpoint (e.g. a configured premium/API key header).
		let requestHeaders = isGitHubReleaseSource ? [:] : headers
		switch await fetcher(requestURL, requestHeaders) {
		case .failure(let error):
			Logger.misc.error(
				"Source fetch FAILED \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"
			)

			return SourceFeedResult(
				identifier: identifier,
				outcome: .failed(
					message: error.localizedDescription,
					rateLimited: Self.isRateLimited(error)
				)
			)

		case .success(let payload):
			guard !payload.isEmpty else {
				return SourceFeedResult(
					identifier: identifier,
					outcome: .failed(message: .localized("Couldn't load this source"), rateLimited: false)
				)
			}

			let feedPayload: Data
			if isGitHubReleaseSource {
				do {
					feedPayload = try GitHubReleaseSource.feedPayload(from: payload, sourceURL: url)
				} catch {
					return SourceFeedResult(
						identifier: identifier,
						outcome: .failed(message: error.localizedDescription, rateLimited: false)
					)
				}
			} else {
				feedPayload = payload
			}

			// The decode that follows runs off the main actor by design, so the
			// "this will block the interface" signal is always false here.
			willDecode?(false)

			// a source that claims a signature is checked before anything from it is
			// published. Unsigned is the normal case and stays accepted; a broken signature is not.
			let provenance = SourceProvenanceVerifier.evaluate(feedPayload)
			SourceProvenanceStore.record(provenance, for: url)

			if case .claimedButInvalid(let reason) = provenance {
				Logger.misc.error(
					"Source signature REJECTED \(url.absoluteString, privacy: .public): \(reason, privacy: .public)"
				)
				return SourceFeedResult(
					identifier: identifier,
					outcome: .failed(message: reason, rateLimited: false)
				)
			}

			do {
				let repository = try Self.decode(feedPayload)
				return SourceFeedResult(identifier: identifier, outcome: .decoded(repository, payload: feedPayload))
			} catch {
				Logger.misc.error(
					"Source decode FAILED \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
				)
				return SourceFeedResult(identifier: identifier, outcome: .invalid(payload: feedPayload))
			}
		}
	}

	/// A 429 is the transport's way of saying "slow down": the source is skipped for the rest of
	/// the round instead of being retried, so it has to be recognised rather than logged.
	static func isRateLimited(_ error: Error) -> Bool {
		guard case NBFetchService.NBFetchServiceError.httpError(429) = error else { return false }
		return true
	}

	/// The decode on its own, so the shape of a feed is testable without a network call.
	static func decode(_ payload: Data) throws -> ASRepository {
		let signpost = SourceFeedSignposts.decode.beginInterval(
			"decode",
			id: SourceFeedSignposts.decode.makeSignpostID()
		)
		defer { SourceFeedSignposts.decode.endInterval("decode", signpost) }

		return try JSONDecoder().decode(ASRepository.self, from: payload)
	}
}

// MARK: - Signposts

/// Instruments: fetch, decode and publish are three phases with very different costs, and the
/// trace says which one a slow refresh is stuck in.
enum SourceFeedSignposts {
	static let loader = OSSignposter(subsystem: "app.vexsign", category: "SourceFeed")
	static let decode = OSSignposter(subsystem: "app.vexsign", category: "SourceFeedDecode")
	static let publish = OSSignposter(subsystem: "app.vexsign", category: "SourceFeedPublish")
}
