//
//  TrollStoreHandoffTests.swift
//  VexSignTests
//
//  The bug these lock in: VexSign opened `trollstore://install?url=…`, a scheme
//  no TrollStore release registers. TrollStore (1.3+) replaces Apple's
//  `apple-magnifier` scheme instead and parses only these two hosts in
//  `TrollStore/TSSceneDelegate.m`:
//
//      apple-magnifier://install?url=<IPA URL>
//      apple-magnifier://enable-jit?bundle-id=<Bundle ID>
//
//  Anything else reaches TrollStore and is ignored, or opens Magnifier.
//

import Testing
import Foundation
@testable import VexSign

@Suite("TrollStore hand-off")
struct TrollStoreHandoffTests {

    @Test("Install URL uses the scheme TrollStore actually registers")
    func installURLUsesMagnifierScheme() {
        let ipa = URL(fileURLWithPath: "/tmp/Signed App.ipa")
        let url = TrollStoreHandoff.installURL(ipaURL: ipa)

        #expect(url?.scheme == "apple-magnifier")
        #expect(url?.host == "install")
        // `trollstore://` is the regression: no release registers it.
        #expect(url?.scheme != "trollstore")
    }

    @Test("The whole IPA URL survives as one query value")
    func installURLCarriesTheIPAURLIntact() throws {
        // A query on the IPA URL is the interesting case: splicing strings
        // instead of building components truncates it at the first `&`.
        let ipa = try #require(URL(string: "https://example.com/app.ipa?token=abc&v=2"))
        let url = try #require(TrollStoreHandoff.installURL(ipaURL: ipa))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        #expect(items.count == 1)
        #expect(items.first?.name == "url")
        #expect(items.first?.value == ipa.absoluteString)

        // TrollStore re-parses this value with NSURL, so it has to round-trip.
        let carried = try #require(URL(string: try #require(items.first?.value)))
        #expect(carried.absoluteString == ipa.absoluteString)
    }

    @Test("A file URL without a query is still preserved exactly")
    func installURLPreservesLocalFileURL() throws {
        let ipa = URL(fileURLWithPath: "/tmp/imports/My%20App.ipa")
        let url = try #require(TrollStoreHandoff.installURL(ipaURL: ipa))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first?.value == ipa.absoluteString)
    }

    @Test("JIT URL targets the documented host and bundle-id key")
    func enableJITURLShape() throws {
        let url = try #require(TrollStoreHandoff.enableJITURL(bundleIdentifier: "com.vexsign.app"))
        #expect(url.scheme == "apple-magnifier")
        #expect(url.host == "enable-jit")

        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items == [URLQueryItem(name: "bundle-id", value: "com.vexsign.app")])
    }

    @Test("A marker-less parent directory reads as not installed, never as an error")
    func detectionWithoutMarkerIsFalse() {
        // The test bundle's parent has no `_TrollStore` marker. The point is that
        // this answers a Bool instead of throwing or asserting that TrollStore
        // is absent from the device.
        let bare = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(TrollStoreHandoff.installedByTrollStore(bundleURL: bare) == false)
    }

    @Test("The marker TrollStore writes is what detection looks for")
    func detectionReadsMarkersBesideTheBundle() throws {
        let container = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = container.appendingPathComponent("VexSign.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(TrollStoreHandoff.installedByTrollStore(bundleURL: bundle) == false)

        // TrollStore uses the Lite marker on TrollStore Lite.
        try Data().write(to: container.appendingPathComponent("_TrollStoreLite"))
        #expect(TrollStoreHandoff.installedByTrollStore(bundleURL: bundle) == true)
    }

    @Test("Availability never claims TrollStore from a scheme probe")
    func availabilityNeedsTheMarker() {
        // `canOpenURL("apple-magnifier://")` is true on every iPhone. If this
        // expectation ever fails, detection went back to a scheme probe.
        let availability = SigningMethodAvailability.current(for: .trollStore)
        #expect(availability.isAvailable == TrollStoreHandoff.installedByTrollStore())
        #expect(availability.isAvailable == (availability.availabilityReason == nil))
    }
}
