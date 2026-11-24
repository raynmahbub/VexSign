//
//  WidgetRepoPayloadTests.swift
//  VexSignTests
//
//  The widget renders a snapshot the app writes into the app group. Until now nothing
//  tested the payload itself, although its icon cache is pruned by file name and its
//  sources are capped.
//

import XCTest
@testable import VexSign

final class WidgetRepoPayloadTests: XCTestCase {

	private func payload() -> WidgetRepoPayload {
		WidgetRepoPayload(
			sources: [
				WidgetRepoPayload.Source(
					url: "https://example.com/first.json",
					name: "First",
					apps: [
						WidgetRepoPayload.App(id: "a", name: "A", bundleID: "com.example.a", version: "1.0", iconFile: "a.png", hasUpdate: true),
						WidgetRepoPayload.App(id: "b", name: "B", bundleID: "com.example.b", version: "2.0", iconFile: nil, hasUpdate: false)
					]
				),
				WidgetRepoPayload.Source(
					url: "https://example.com/second.json",
					name: "Second",
					apps: [
						WidgetRepoPayload.App(id: "c", name: "C", bundleID: "com.example.c", version: "3.0", iconFile: nil, hasUpdate: false)
					]
				)
			],
			lastUpdated: Date()
		)
	}

	func testIconNamesAreStablePerURLAcrossBuilds() throws {
		let first = try XCTUnwrap(URL(string: "https://example.com/icons/a.png"))
		let second = try XCTUnwrap(URL(string: "https://example.com/icons/b.png"))

		let name = WidgetRepoPayload.iconFileName(for: first)
		XCTAssertEqual(name, WidgetRepoPayload.iconFileName(for: first), "the pruner compares file names with a payload")
		XCTAssertNotEqual(name, WidgetRepoPayload.iconFileName(for: second))
		XCTAssertTrue(name.hasSuffix(".png"))
		XCTAssertEqual(name.count, 68, "SHA-256 in hex plus the extension")
	}

	func testAppsAreFilteredBySource() {
		let payload = payload()

		XCTAssertEqual(payload.apps(in: "https://example.com/second.json").map(\.id), ["c"])
		XCTAssertEqual(payload.apps(in: "https://example.com/unknown.json"), [])
		XCTAssertEqual(payload.apps(in: nil).count, payload.appCount)
	}

	func testStalenessIsADay() {
		var payload = payload()
		payload.lastUpdated = Date().addingTimeInterval(-90)
		XCTAssertFalse(payload.isStale)

		payload.lastUpdated = Date().addingTimeInterval(-60 * 60 * 25)
		XCTAssertTrue(payload.isStale)
	}

	func testPayloadRoundTripsThroughTheSharedEncoding() throws {
		let original = payload()
		let data = try JSONEncoder().encode(original)
		let decoded = try JSONDecoder().decode(WidgetRepoPayload.self, from: data)

		XCTAssertEqual(decoded.sources, original.sources)
		XCTAssertEqual(decoded.lastUpdated.timeIntervalSince1970,
					   original.lastUpdated.timeIntervalSince1970,
					   accuracy: 1.0, "the widget only cares about the second")
	}
}
