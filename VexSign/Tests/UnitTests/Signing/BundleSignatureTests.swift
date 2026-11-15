//
//  BundleSignatureTests.swift
//  VexSignTests
//
//  Fixture-based tests for who signed a stored bundle, and when that identity expires.
//
//  The fixtures are synthetic public test evidence: a self-signed certificate and CMS SignedData that
//  openssl produced from it, embedded as base64 so the suite needs no files, no keychain and no
//  device. The executable the end-to-end tests read is built here byte by byte — an arm64 Mach-O
//  header with one `LC_CODE_SIGNATURE` command in front of a real superblob — because that is
//  exactly what `BundleSignature` walks on a device.
//
//  Expected values (openssl, at fixture time):
//    subject CN   VexSign Fixture Signer
//    serial       4D781C6BFEF80481F72C8B6BDA035ACD4456AAB3
//    notBefore    2026-10-31T23:41:48Z
//    notAfter     2027-12-05T23:41:48Z
//    sha256(DER)  1cc79e23acbd34c625de9c48d33eda8ff1f7b024f7dbccfa324e2d759bab3a16
//

import Foundation
import NimbleExtensions
import XCTest
import os
@testable import VexSign

final class BundleSignatureTests: XCTestCase {
	// MARK: Fixtures





	private let expectedFingerprint = "1cc79e23acbd34c625de9c48d33eda8ff1f7b024f7dbccfa324e2d759bab3a16"
	private let expectedCommonName = "VexSign Fixture Signer"
	private let expectedSerial = "4D781C6BFEF80481F72C8B6BDA035ACD4456AAB3"
	private let notBefore = Date(timeIntervalSince1970: 1_793_490_108)
	private let notAfter = Date(timeIntervalSince1970: 1_828_050_108)

	private var certificateDER: Data {
		SigningRegressionFixture.certificateDER
	}

	private var cms: Data {
		SigningRegressionFixture.cms
	}

	// MARK: DER

	func testDERReadsShortAndLongFormLengths() {
		let short: [UInt8] = [0x04, 0x03, 0x01, 0x02, 0x03]
		let element = DER.element(short, at: 0)
		XCTAssertEqual(element?.tag, 0x04)
		XCTAssertEqual(element?.contentLength, 3)
		XCTAssertEqual(element.map { DER.content(of: $0, in: short) }, [0x01, 0x02, 0x03])

		// 130 bytes needs the long form: 0x81 0x82.
		var long: [UInt8] = [0x04, 0x81, 130]
		long += Array(repeating: 0x41, count: 130)
		let longElement = DER.element(long, at: 0)
		XCTAssertEqual(longElement?.contentLength, 130)
		XCTAssertEqual(longElement?.end, long.count)
	}

	func testDERRefusesMalformedLengths() {
		// Indefinite length is BER, not DER.
		XCTAssertNil(DER.element([0x30, 0x80, 0x00, 0x00], at: 0))
		// Truncated content.
		XCTAssertNil(DER.element([0x04, 0x05, 0x01, 0x02], at: 0))
		// Non-minimal long form (0x81 0x05 would fit in one octet).
		var nonMinimal: [UInt8] = [0x04, 0x81, 0x05]
		nonMinimal += Array(repeating: 0x41, count: 5)
		XCTAssertNil(DER.element(nonMinimal, at: 0))
		// Too few bytes to hold a header at all.
		XCTAssertNil(DER.element([0x30], at: 0))
		XCTAssertNil(DER.element([], at: 0))
	}

	func testDERChildrenMustFillTheirParent() {
		// A SEQUENCE declaring four bytes of content, holding one three-byte element.
		let ragged: [UInt8] = [0x30, 0x04, 0x04, 0x03, 0x01, 0x02, 0x03]
		XCTAssertNil(DER.element(ragged, at: 0).flatMap { DER.children(ragged, in: $0) })

		// The same shape, sized to fit.
		let tidy: [UInt8] = [0x30, 0x02, 0x05, 0x00]
		let tidyElement = DER.element(tidy, at: 0)
		XCTAssertEqual(tidyElement.flatMap { DER.children(tidy, in: $0) }?.count, 1)
	}

	func testNestedDocumentStaysBounded() {
		// 40 nested SEQUENCEs, each wrapping the next. Parsing must stay flat and finite.
		var bytes: [UInt8] = [0x05, 0x00]
		for _ in 0..<40 {
			bytes = [0x30, UInt8(bytes.count)] + bytes
		}
		let outer = DER.element(bytes, at: 0)
		XCTAssertEqual(outer?.end, bytes.count)
	}

	// MARK: X.509

	func testFixtureCertificateYieldsItsIdentity() throws {
		let identity = try XCTUnwrap(SigningIdentity(certificateDER))

		XCTAssertEqual(identity.fingerprint, expectedFingerprint)
		XCTAssertEqual(identity.commonName, expectedCommonName)
		XCTAssertEqual(identity.serial, expectedSerial)
		XCTAssertEqual(identity.notBefore, notBefore)
		XCTAssertEqual(identity.notAfter, notAfter)
		XCTAssertEqual(identity.displayName, expectedCommonName)
		XCTAssertEqual(identity.shortFingerprint, "1CC79E23")
	}

	func testGarbageIsNotACertificate() {
		XCTAssertNil(SigningIdentity(Data()))
		XCTAssertNil(SigningIdentity(Data([0x00, 0x01, 0x02, 0x03])))
		XCTAssertNil(SigningIdentity(Data(repeating: 0xff, count: 64)))

		// A well-formed SEQUENCE that is not a certificate.
		XCTAssertNil(SigningIdentity(Data([0x30, 0x00])))

		// A certificate truncated mid-way through its validity field.
		XCTAssertNil(SigningIdentity(certificateDER.prefix(certificateDER.count / 2)))
	}

	func testExpiryMath() throws {
		let identity = try XCTUnwrap(SigningIdentity(certificateDER))
		let day: TimeInterval = 86_400

		XCTAssertFalse(identity.isExpired(at: notAfter.addingTimeInterval(-1)))
		XCTAssertTrue(identity.isExpired(at: notAfter))
		XCTAssertTrue(identity.isExpired(at: notAfter.addingTimeInterval(day)))

		XCTAssertEqual(identity.daysRemaining(from: notBefore), 400)
		XCTAssertEqual(identity.daysRemaining(from: notAfter.addingTimeInterval(-day / 2)), 0)
		XCTAssertEqual(identity.daysRemaining(from: notAfter.addingTimeInterval(day * 2)), -2)
	}

	func testACertificateWithoutAnExpiryIsNeverCalledExpired() {
		let unknown = SigningIdentity(fingerprint: expectedFingerprint)
		XCTAssertNil(unknown.notAfter)
		XCTAssertNil(unknown.daysRemaining())
		XCTAssertFalse(unknown.isExpired(at: .distantFuture))
		XCTAssertEqual(unknown.displayName, String.localized("an unnamed certificate"))
	}

	// MARK: CMS

	func testCMSFixtureCarriesItsSigner() throws {
		let certificates = try XCTUnwrap(BundleSignature.certificateDERs(inCMS: cms))
		XCTAssertEqual(certificates.count, 1)

		let der = try XCTUnwrap(certificates.first)
		XCTAssertEqual(SigningIdentity.fingerprint(of: der), expectedFingerprint)
		XCTAssertEqual(der, certificateDER)
	}

	func testCMSWithoutSignerInfosIsMalformedNotAnAdHocSignature() throws {
		// This incomplete SignedData has neither certificates nor required SignerInfos.
        // Ad-hoc Mach-O signatures omit the CMS slot; they do not forge SignedData.
		// ContentInfo is the SEQUENCE around the content type, as in the fixture above.
		let contentInfo = Data(der([
			tlv(0x30, der([
				tlv(0x06, oidSignedData), // contentType: id-signedData
				tlv(0xa0, der([          // [0] EXPLICIT SignedData
					tlv(0x30, der([
						tlv(0x02, [0x01]), // version
						tlv(0x31, []),     // digestAlgorithms
						tlv(0x30, [])      // encapContentInfo
					]))
				]))
			]))
		]))

        XCTAssertNil(BundleSignature.certificateDERs(inCMS: contentInfo))
	}

	func testMalformedCMSReturnsNil() {
		XCTAssertNil(BundleSignature.certificateDERs(inCMS: Data()))
		XCTAssertNil(BundleSignature.certificateDERs(inCMS: Data([0x30, 0x00])))
		XCTAssertNil(BundleSignature.certificateDERs(inCMS: cms.prefix(cms.count / 2)))
	}

	// MARK: Superblob

	func testSuperblobReturnsTheSignatureSlot() throws {
		let superblob = makeSuperblob([(5, Data("entitlements".utf8)), (0x10000, cms)])
		let blob = try XCTUnwrap(BundleSignature.certificateBlob(inSuperblob: [UInt8](superblob)))
		XCTAssertEqual(blob, cms)
	}

	func testSuperblobWithoutTheSignatureSlotIsNil() {
		let superblob = makeSuperblob([(5, Data("entitlements".utf8))])
		XCTAssertNil(BundleSignature.certificateBlob(inSuperblob: [UInt8](superblob)))
	}

	func testSuperblobRefusesOffsetsOutsideItself() {
		// One entry whose offset points past the end of the blob.
		var bytes = Data()
		bytes.append(u32(0xfade_0cc0))
		bytes.append(u32(24))
		bytes.append(u32(1))
		bytes.append(u32(0x10000))
		bytes.append(u32(4096))
		XCTAssertNil(BundleSignature.certificateBlob(inSuperblob: [UInt8](bytes)))

		// A count that promises more entries than the blob can hold.
		var overlong = Data()
		overlong.append(u32(0xfade_0cc0))
		overlong.append(u32(12))
		overlong.append(u32(0x7fff_ffff))
		XCTAssertNil(BundleSignature.certificateBlob(inSuperblob: [UInt8](overlong)))
	}

	// MARK: End to end

	func testASignedExecutableYieldsItsSigner() throws {
		let url = try writeExecutable(superblob: makeSuperblob([(0x10000, cms)]))
		defer { try? FileManager.default.removeItem(at: url) }

		guard case .certificates(let identities) = BundleSignature.read(executableAt: url) else {
			return XCTFail("expected certificates")
		}
		XCTAssertEqual(identities.count, 1)
		XCTAssertEqual(identities.first?.fingerprint, expectedFingerprint)
		XCTAssertEqual(identities.first?.commonName, expectedCommonName)
		XCTAssertEqual(identities.first?.notAfter, notAfter)
	}

	func testAnExecutableWithoutACodeSignatureSaysSo() throws {
		let url = try writeExecutable(superblob: nil)
		defer { try? FileManager.default.removeItem(at: url) }

		XCTAssertEqual(BundleSignature.read(executableAt: url), .noCodeSignature)
	}

	func testAnAdHocSignatureHasNoCertificate() throws {
		let url = try writeExecutable(superblob: makeSuperblob([(5, Data("entitlements".utf8))]))
		defer { try? FileManager.default.removeItem(at: url) }

		XCTAssertEqual(BundleSignature.read(executableAt: url), .noCertificates)
	}

	func testACorruptSuperblobIsUnreadableNotUnsigned() throws {
		// Signed, but the declared superblob length runs past the end of the file.
		var bytes = [UInt8](machO(superblobLength: 9_999_999, superblob: makeSuperblob([(0x10000, cms)])))
		bytes.removeLast(64)

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("VexSignTests-\(UUID().uuidString)")
		try Data(bytes).write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }

		guard case .unreadable = BundleSignature.read(executableAt: url) else {
			return XCTFail("expected unreadable")
		}
	}

	// MARK: Match

	func testTheSameCertificateMatches() throws {
		let identity = try XCTUnwrap(SigningIdentity(certificateDER))
		let match = SignerMatch.evaluate(bundle: [identity], selected: [identity], selectedLabel: "“Dev”")

		guard case .same(let signer) = match else { return XCTFail("expected same") }
		XCTAssertEqual(signer.fingerprint, expectedFingerprint)
		XCTAssertFalse(match.isMismatch)
		XCTAssertNil(match.detail)
	}

	func testADifferentCertificateIsAMismatch() throws {
		let bundle = try XCTUnwrap(SigningIdentity(certificateDER))
		let selected = SigningIdentity(fingerprint: String(repeating: "ab", count: 32), commonName: "Other")

		let match = SignerMatch.evaluate(bundle: [bundle], selected: [selected], selectedLabel: "“Other”")
		guard case .different(let signer, let label) = match else { return XCTFail("expected different") }
		XCTAssertEqual(signer.fingerprint, expectedFingerprint)
		XCTAssertEqual(label, "“Other”")
		XCTAssertTrue(match.isMismatch)

		let detail = try XCTUnwrap(match.detail)
		XCTAssertTrue(detail.contains(expectedCommonName))
		XCTAssertTrue(detail.contains("“Other”"))
	}

	func testAChainThatContainsTheSelectedCertificateMatches() throws {
		let signer = try XCTUnwrap(SigningIdentity(certificateDER))
		let intermediate = SigningIdentity(fingerprint: String(repeating: "cd", count: 32), commonName: "CA")

		let match = SignerMatch.evaluate(bundle: [signer, intermediate], selected: [intermediate], selectedLabel: "x")
		XCTAssertFalse(match.isMismatch)
		XCTAssertEqual(match.signer?.commonName, "CA")
	}

	func testNoCertificatesOnEitherSideIsUnknown() throws {
		let identity = try XCTUnwrap(SigningIdentity(certificateDER))

		XCTAssertFalse(SignerMatch.evaluate(bundle: [], selected: [identity], selectedLabel: "x").isMismatch)
		XCTAssertFalse(SignerMatch.evaluate(bundle: [identity], selected: [], selectedLabel: "x").isMismatch)

		guard case .unknown = SignerMatch.evaluate(bundle: [], selected: [identity], selectedLabel: "x") else {
			return XCTFail("an empty bundle must be unknown, never a mismatch")
		}
	}

	// MARK: Store

	func testResolvePrefersTheDeviceOverTheLibrary() {
		let probe = StubProbe(app: InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, version: "1.0"))
		let request = LibraryStatusStore.Request(
			uuid: "uuid",
			bundleIdentifier: "com.example.app",
			expectedVersion: "1.2",
			bundleURL: nil,
			isSigned: false
		)

		let status = LibraryStatusStore.resolve(request, probe: probe) { _ in
			XCTFail("an unsigned app has no bundle to read")
			return .noCodeSignature
		}

		XCTAssertEqual(status.installed, .installedOtherVersion("1.0"))
		XCTAssertNil(status.signature)
		XCTAssertTrue(status.isKnown)
	}

	func testResolveRejectsDeviceEvidenceForAnotherBundle() {
		let request = LibraryStatusStore.Request(uuid: "row", bundleIdentifier: "requested.app",
			expectedVersion: "1", bundleURL: nil, isSigned: false)
		let status = LibraryStatusStore.resolve(request,
			probe: StubProbe(app: InstalledApp(bundleIdentifier: "different.host", isInstalled: true, version: "1")),
			readSignature: { _ in .unreadable("Unexpected signature read") })
		XCTAssertEqual(status.installed, .unknown)
	}

	func testResolveKeepsUnknownWhenTheProbeCannotAnswer() {
		let request = LibraryStatusStore.Request(
			uuid: "uuid",
			bundleIdentifier: "com.example.app",
			expectedVersion: "1.0",
			bundleURL: nil,
			isSigned: false
		)

		let status = LibraryStatusStore.resolve(request, probe: StubProbe(app: nil)) { _ in .noCodeSignature }
		XCTAssertEqual(status.installed, .unknown)

		// A request with no identifier cannot claim anything either.
		let anonymous = LibraryStatusStore.Request(
			uuid: "u",
			bundleIdentifier: nil,
			expectedVersion: "1.0",
			bundleURL: nil,
			isSigned: false
		)
		let resolved = LibraryStatusStore.resolve(anonymous, probe: StubProbe(app: nil)) { _ in .noCodeSignature }
		XCTAssertEqual(resolved.installed, .unknown)
	}

	func testResolveReadsTheSignatureOfSignedApps() throws {
		let identity = try XCTUnwrap(SigningIdentity(certificateDER))
		let request = LibraryStatusStore.Request(
			uuid: "uuid",
			bundleIdentifier: "com.example.app",
			expectedVersion: "1.0",
			bundleURL: URL(fileURLWithPath: "/tmp/does-not-need-to-exist"),
			isSigned: true
		)

		let status = LibraryStatusStore.resolve(
			request,
			probe: StubProbe(app: InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true, version: "1.0"))
		) { _ in .certificates([identity]) }

		XCTAssertEqual(status.signature?.signer?.fingerprint, expectedFingerprint)
		XCTAssertEqual(status.expiresAt, notAfter)
		XCTAssertEqual(status.installed, .installed)
		XCTAssertEqual(status.bundleIdentifier, "com.example.app")
	}

	func testSignatureRowsNeverTurnUnknownIntoMissing() {
		let unknown = LibraryAppStatus()
		XCTAssertEqual(unknown.signatureRows().first?.value, InstalledState.unknown.title)

		let missing = LibraryAppStatus(installed: .notInstalled)
		XCTAssertEqual(missing.signatureRows().first?.value, String.localized("Not installed"))

		let adHoc = LibraryAppStatus(installed: .installed, signature: .noCertificates)
		XCTAssertTrue(adHoc.signatureRows().contains { $0.title == String.localized("Signature") })
	}

	func testSignatureRowsNameTheSignerAndItsExpiry() throws {
		let identity = try XCTUnwrap(SigningIdentity(certificateDER))
		let status = LibraryAppStatus(installed: .installed, signature: .certificates([identity]))
		let rows = status.signatureRows(certificateRow: "Matches")

		XCTAssertEqual(rows.count, 6)
		XCTAssertEqual(rows[1].value, expectedCommonName)
		XCTAssertEqual(rows[2].value, expectedSerial)
		XCTAssertEqual(rows[3].value, identity.shortFingerprint)
		XCTAssertEqual(rows[5].value, "Matches")
	}

	func testBadgesShowCheckingAndUnknownWithoutGuessingInstallState() {
		let checking = InstalledBadge(LibraryAppStatus())
		XCTAssertEqual(checking.title, String.localized("Checking…"))
		XCTAssertEqual(checking.tone, .neutral)

		var unavailableStatus = LibraryAppStatus()
		unavailableStatus.updatedAt = Date()
		let unavailable = InstalledBadge(unavailableStatus)
		XCTAssertEqual(unavailable.title, String.localized("Unknown"))
		XCTAssertEqual(unavailable.tone, .neutral)
	}

	func testBadgesSayNothingWhenTheProbeCannotWithoutLifecycleContext() {
		XCTAssertNil(InstalledBadge(.unknown))

		let installed = InstalledBadge(.installed)
		XCTAssertEqual(installed?.title, String.localized("Installed"))
		XCTAssertEqual(installed?.tone, .positive)

		let other = InstalledBadge(.installedOtherVersion("1.2"))
		XCTAssertEqual(other?.title, "v1.2")
		XCTAssertEqual(other?.tone, .warning)

		let missing = InstalledBadge(.notInstalled)
		XCTAssertEqual(missing?.title, String.localized("Not installed"))
		XCTAssertEqual(missing?.tone, .neutral)
	}

    @MainActor
    func testConfirmedInstallImmediatelyUpdatesVisibleAndLaterMountedRows() async throws {
        let store = LibraryStatusStore(probe: StubProbe(app: nil), readSignature: { _ in .noCodeSignature })
        store.selectDevice(binding: InstallationEvidenceTestFixtures.binding)
        let request = LibraryStatusStore.Request(uuid: "visible", bundleIdentifier: "example.app", expectedVersion: "1", bundleURL: nil, isSigned: true, expectedBuild: "1")
        store.request(request)
        try await waitUntil { store.statuses["visible"]?.isKnown == true }
        store.recordInstalledApplicationObservation(InstallationEvidenceTestFixtures.application(identifier: "example.app", version: "1", build: "1"))
        XCTAssertEqual(store.statuses["visible"]?.installed, .installed)
        let visibleSeed = store.statuses["visible"]?.updatedAt
        let later = LibraryStatusStore.Request(uuid: "later", bundleIdentifier: "example.app", expectedVersion: "2", bundleURL: nil, isSigned: true, expectedBuild: "1")
        store.request(later)
        XCTAssertEqual(store.statuses["later"]?.installed, .installedOtherVersion("1"))
        let laterSeed = store.statuses["later"]?.updatedAt
        // Wait for both actual publications, not an arbitrary sleep.
        try await waitUntil {
            store.statuses["visible"]?.updatedAt != visibleSeed && store.statuses["later"]?.updatedAt != laterSeed
        }
        XCTAssertEqual(store.statuses["visible"]?.installed, .installed)
        XCTAssertEqual(store.statuses["later"]?.installed, .installedOtherVersion("1"))
    }

    @MainActor
    func testConfirmedInstallDoesNotLeakToOtherIdentifiersOrSurviveReset() {
        let store = LibraryStatusStore(probe: StubProbe(app: nil))
        store.selectDevice(binding: InstallationEvidenceTestFixtures.binding)
        store.recordInstalledApplicationObservation(InstallationEvidenceTestFixtures.application(identifier: "example.app", version: "1", build: "1"))
        let other = LibraryStatusStore.Request(uuid: "other", bundleIdentifier: "other.app", expectedVersion: "1", bundleURL: nil, isSigned: false, expectedBuild: "1")
        store.request(other)
        XCTAssertNotEqual(store.statuses["other"]?.installed, .installed)
        store.invalidateAll()
        let request = LibraryStatusStore.Request(uuid: "reset", bundleIdentifier: "example.app", expectedVersion: "1", bundleURL: nil, isSigned: false, expectedBuild: "1")
        store.request(request)
        XCTAssertNotEqual(store.statuses["reset"]?.installed, .installed)
    }

    @MainActor
    func testOldConfirmationCannotMarkAnAppInstalled() {
        let store = LibraryStatusStore(probe: StubProbe(app: nil))
        store.selectDevice(binding: InstallationEvidenceTestFixtures.binding)
        store.recordInstalledApplicationObservation(InstallationEvidenceTestFixtures.application(identifier: "example.app", version: "1", build: "1", at: Date().addingTimeInterval(-60)))
        let request = LibraryStatusStore.Request(uuid: "expired", bundleIdentifier: "example.app", expectedVersion: "1", bundleURL: nil, isSigned: false, expectedBuild: "1")
        store.request(request)
        XCTAssertNotEqual(store.statuses["expired"]?.installed, .installed)
    }

	@MainActor
	func testInvalidationImmediatelyRefreshesAnAlreadyVisibleRow() async throws {
		let probe = ControlledLibraryProbe()
		defer { probe.releaseAll() }
		let store = LibraryStatusStore(probe: probe)
		let request = LibraryStatusStore.Request(uuid: "row", bundleIdentifier: "example.app", expectedVersion: "1", bundleURL: nil, isSigned: true)
		store.request(request)
		try await waitUntil { probe.count == 1 }
		probe.first.signal()
		try await waitUntil { store.statuses["row"] != nil }
		XCTAssertEqual(store.statuses["row"]?.installed, .notInstalled)
		store.invalidate(bundleIdentifier: "example.app")
		try await waitUntil { probe.count == 2 }
		probe.second.signal()
		try await waitUntil { store.statuses["row"]?.installed == .installed }
	}

	@MainActor
	func testInvalidationRefreshesPendingRowAndRejectsOldCompletion() async throws {
		try await exerciseSupersededRead(resetAll: false)
	}

	@MainActor
	func testOldCompletionDoesNotClearNewReadInFlight() async throws {
		let probe = ControlledLibraryProbe()
		defer { probe.releaseAll() }
		let store = LibraryStatusStore(probe: probe)
		let request = LibraryStatusStore.Request(uuid: "row", bundleIdentifier: "example.app", expectedVersion: "1", bundleURL: nil, isSigned: true)
		store.request(request)
		try await waitUntil { probe.count == 1 }
		store.invalidate(bundleIdentifier: "example.app")
		try await waitUntil { probe.count == 2 }
		probe.first.signal()
		try await waitUntil { probe.returned == 1 }
		try await Task.sleep(nanoseconds: 100_000_000)
		XCTAssertNil(store.statuses["row"])
		// An ordinary read must not replace the still-pending newer probe.
		store.request(request, maxAge: 0)
		try await Task.sleep(nanoseconds: 100_000_000)
		XCTAssertEqual(probe.count, 2)
		probe.second.signal()
		try await waitUntil { store.statuses["row"]?.installed == .installed }
	}

	@MainActor
	func testResetFencesOldReadsEvenWhenEpochIsReused() async throws {
		try await exerciseSupersededRead(resetAll: true)
	}

	@MainActor
	private func exerciseSupersededRead(resetAll: Bool) async throws {
		let probe = ControlledLibraryProbe()
		defer { probe.releaseAll() }
		let store = LibraryStatusStore(probe: probe)
		let request = LibraryStatusStore.Request(uuid: "row", bundleIdentifier: "example.app", expectedVersion: "1", bundleURL: nil, isSigned: true)
		store.request(request)
		try await waitUntil { probe.count == 1 }
		if resetAll {
			store.invalidateAll()
			store.request(request)
		} else {
			store.invalidate(bundleIdentifier: "example.app")
		}
		try await waitUntil { probe.count == 2 }
		probe.second.signal()
		try await waitUntil { store.statuses["row"]?.installed == .installed }
		probe.first.signal()
		// Let the detached result return, then allow its main-actor delivery to run.
		try await waitUntil { probe.returned == 2 }
		try await Task.sleep(nanoseconds: 100_000_000)
		XCTAssertEqual(store.statuses["row"]?.installed, .installed)
	}

	@MainActor
	private func waitUntil(_ condition: () -> Bool) async throws {
		for _ in 0..<500 {
			if condition() { return }
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		XCTFail("Timed out waiting for status read")
		throw NSError(domain: "LibraryStatusTests", code: 1)
	}

	// MARK: Helpers

	/// The `id-signedData` content type, 1.2.840.113549.1.7.2.
	private var oidSignedData: [UInt8] {
		[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02]
	}

	/// One DER element with a single-octet length. Enough for the fixtures above.
	private func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
		precondition(content.count < 0x80)
		return [tag, UInt8(content.count)] + content
	}

	private func der(_ parts: [[UInt8]]) -> [UInt8] {
		parts.flatMap { $0 }
	}

	/// `superblobMagic, length, count` then `(slot, offset)` pairs then the wrapped blobs.
	private func makeSuperblob(_ entries: [(UInt32, Data)]) -> Data {
		let headerLength = 12 + entries.count * 8
		var offset = headerLength
		var table = Data()
		var bodies = Data()

		for (slot, blob) in entries {
			var wrapper = Data()
			wrapper.append(u32(0xfade_0b01)) // CSMAGIC_BLOBWRAPPER
			wrapper.append(u32(UInt32(8 + blob.count)))
			wrapper.append(blob)

			table.append(u32(slot))
			table.append(u32(UInt32(offset)))
			offset += wrapper.count
			bodies.append(wrapper)
		}

		var superblob = Data()
		superblob.append(u32(0xfade_0cc0)) // CSMAGIC_EMBEDDED_SIGNATURE
		superblob.append(u32(UInt32(offset)))
		superblob.append(u32(UInt32(entries.count)))
		superblob.append(table)
		superblob.append(bodies)
		return superblob
	}

	/// An arm64 Mach-O with one `LC_CODE_SIGNATURE` command, or a non-signature command.
	private func machO(superblobLength: UInt32?, superblob: Data) -> Data {
		let headerSize = 32
		let commandSize = 16

		var data = Data()
		data.append(u32le(0xfeed_facf)) // MH_MAGIC_64
		data.append(u32le(0x0100_000c)) // CPU_TYPE_ARM64
		data.append(u32le(0))
		data.append(u32le(2))           // MH_EXECUTE
		data.append(u32le(1))           // ncmds
		data.append(u32le(UInt32(commandSize)))
		data.append(u32le(0))
		data.append(u32le(0))

		if let superblobLength {
			data.append(u32le(0x1d))    // LC_CODE_SIGNATURE
			data.append(u32le(UInt32(commandSize)))
			data.append(u32le(UInt32(headerSize + commandSize)))
			data.append(u32le(superblobLength))
		} else {
			data.append(u32le(0x19))    // LC_SEGMENT_64 — not a code signature
			data.append(u32le(UInt32(commandSize)))
		}

		data.append(superblob)
		return data
	}

	private func writeExecutable(superblob: Data?) throws -> URL {
		let body = superblob ?? Data()
		let data = machO(superblobLength: superblob.map { UInt32($0.count) }, superblob: body)

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("VexSignTests-\(UUID().uuidString)")
		try data.write(to: url)
		return url
	}

	/// Big-endian, for the code signature superblob (which is always big-endian).
	private func u32(_ value: UInt32) -> Data {
		var bigEndian = value.bigEndian
		return withUnsafeBytes(of: &bigEndian) { Data($0) }
	}

	/// Little-endian, for arm64 Mach-O headers and load commands.
	private func u32le(_ value: UInt32) -> Data {
		var littleEndian = value.littleEndian
		return withUnsafeBytes(of: &littleEndian) { Data($0) }
	}
}

// MARK: - Stub

/// A probe with one fixed answer, so the store's derivation can be tested without a device.
private struct StubProbe: InstalledAppProbing {
	let app: InstalledApp?

	func installedApp(for bundleIdentifier: String) -> InstalledApp? {
		app
	}
}

/// Independently release reads so an old negative can arrive after a new positive.
private final class ControlledLibraryProbe: InstalledAppProbing {
	private let state = OSAllocatedUnfairLock(initialState: (started: 0, returned: 0))
	let first = DispatchSemaphore(value: 0)
	let second = DispatchSemaphore(value: 0)
	var count: Int { state.withLock { $0.started } }
	var returned: Int { state.withLock { $0.returned } }
	func releaseAll() { first.signal(); second.signal() }

	func installedApp(for bundleIdentifier: String) -> InstalledApp? {
		let index = state.withLock { value in
			value.started += 1
			return value.started
		}
		_ = (index == 1 ? first : second).wait(timeout: .now() + 10)
		defer { state.withLock { $0.returned += 1 } }
		return InstalledApp(bundleIdentifier: bundleIdentifier, isInstalled: index != 1, version: "1")
	}
}
