//
//  TweakCompatibilityTests.swift
//  VexSignTests
//
//  The rules that decide whether a tweak may be injected. Every binary is built in memory;
//  no real tweak, library or package is used.
//

import Foundation
import XCTest
@testable import VexSign

final class TweakCompatibilityTests: XCTestCase {
	// MARK: - Fixtures

	private let arm64: UInt32 = 0x0100_000c
	private let x86_64: UInt32 = 0x0100_0007

	private func word(_ value: UInt32, bigEndian: Bool = false) -> [UInt8] {
		(0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32((bigEndian ? 3 - $0 : $0) * 8)) }
	}

	/// `LC_LOAD_DYLIB` by default; `0x8000_0018` is the weak form, `0x8000_001f` a re-export.
	private func load(_ path: String, command: UInt32 = 0x0c) -> [UInt8] {
		var name = Array(path.utf8) + [0]
		while name.count % 4 != 0 { name.append(0) }
		return word(command) + word(UInt32(24 + name.count)) + word(24) + word(2) + word(0) + word(0x10000) + name
	}

	private func buildVersion(platform: UInt32) -> [UInt8] {
		word(0x32) + word(24) + word(platform) + word(0x000f_0000) + word(0x0011_0000) + word(0)
	}

	private func encryption(cryptID: UInt32) -> [UInt8] {
		word(0x2c) + word(24) + word(0) + word(0) + word(cryptID) + word(0)
	}

	private func image(cpu: UInt32? = nil, subtype: UInt32 = 0, _ commands: [[UInt8]] = []) -> Data {
		let body = commands.flatMap { $0 }
		var bytes: [UInt8] = []
		bytes += word(0xfeed_facf) + word(cpu ?? arm64) + word(subtype) + word(6)
		bytes += word(UInt32(commands.count)) + word(UInt32(body.count)) + word(0) + word(0)
		return Data(bytes + body)
	}

	private func universal(_ slices: [(cpu: UInt32, subtype: UInt32, image: Data)]) -> Data {
		var header: [UInt8] = word(0xcafe_babe, bigEndian: true) + word(UInt32(slices.count), bigEndian: true)
		var offset = 8 + 20 * slices.count
		for slice in slices {
			header += word(slice.cpu, bigEndian: true) + word(slice.subtype, bigEndian: true)
			header += word(UInt32(offset), bigEndian: true) + word(UInt32(slice.image.count), bigEndian: true)
			header += word(0, bigEndian: true)
			offset += slice.image.count
		}
		return slices.reduce(into: Data(header)) { $0.append($1.image) }
	}

	private func codes(_ data: Data) -> [TweakCompatibility.Finding.Code] {
		TweakCompatibility.evaluate(binary: MachOInspector.inspect(data)).map(\.code)
	}

	private let systemLoads = [
		"/usr/lib/libobjc.A.dylib",
		"/usr/lib/libSystem.B.dylib",
		"/System/Library/Frameworks/Foundation.framework/Foundation",
		"/usr/lib/swift/libswiftCore.dylib"
	]

	// MARK: - Binaries that may be injected

	func testAnIOSArm64LibraryThatLoadsOnlyTheSystemHasNoFindings() {
		let data = image([buildVersion(platform: 2)] + systemLoads.map { load($0) })
		XCTAssertEqual(codes(data), [])
	}

	func testBundleRelativeLoadsAreNotAProblem() {
		let data = image([
			load("@rpath/Orion.framework/Orion"),
			load("@executable_path/Frameworks/Helper.dylib"),
			load("@loader_path/Sibling.dylib")
		])
		XCTAssertEqual(codes(data), [])
	}

	func testALibraryThatDoesNotNameItsPlatformIsNotHeldAgainstIt() {
		// Older toolchains wrote no platform at all; absence is not evidence of a wrong one.
		XCTAssertEqual(codes(image(systemLoads.map { load($0) })), [])
	}

	func testEverySpellingOfTheHookRuntimeIsRedirectedRatherThanRefused() {
		let spellings = [
			"/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			"/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			"/usr/lib/libsubstrate.dylib",
			"/var/jb/usr/lib/libsubstrate.dylib",
			"/var/jb/usr/lib/libellekit.dylib"
		]
		let data = image(spellings.map { load($0) })
		let inspection = MachOInspector.inspect(data)

		XCTAssertEqual(TweakCompatibility.evaluate(binary: inspection), [])
		XCTAssertEqual(TweakCompatibility.hookRuntimeLoadPaths(in: inspection), spellings)
	}

	func testTheEmbeddedHookRuntimePathIsLeftAlone() {
		let inspection = MachOInspector.inspect(image([load(TweakCompatibility.embeddedHookRuntimePath)]))
		XCTAssertEqual(TweakCompatibility.hookRuntimeLoadPaths(in: inspection), [])
		XCTAssertEqual(TweakCompatibility.classify(loadPath: TweakCompatibility.embeddedHookRuntimePath), .bundleRelative)
	}

	func testAUniversalLibraryWithArm64AndArm64eIsAccepted() {
		let data = universal([
			(arm64, 0, image([buildVersion(platform: 2)])),
			(arm64, 0x8000_0002, image(subtype: 0x8000_0002, [buildVersion(platform: 2)]))
		])
		XCTAssertEqual(codes(data), [])
	}

	// MARK: - Binaries that must be refused

	func testAFileThatIsNotMachOIsRefused() {
		XCTAssertEqual(codes(Data("#!/bin/sh\necho tweak\n".utf8)), [.notMachO])
		XCTAssertEqual(codes(Data()), [.notMachO])
	}

	func testALibraryForAnotherProcessorIsRefused() {
		XCTAssertEqual(codes(image(cpu: x86_64)), [.noDeviceSlice(architectures: ["x86_64"])])
	}

	func testAnArm64eOnlyLibraryIsRefused() {
		// A sideloaded app is an arm64 process; dyld will not load an arm64e-only image into it.
		XCTAssertEqual(codes(image(subtype: 2)), [.arm64eOnly])
		// What toolchains actually write: the subtype with the pointer-authentication flag.
		XCTAssertEqual(codes(image(subtype: 0x8000_0002)), [.arm64eOnly])
	}

	func testTheArm64eCapabilityFlagIsNotMistakenForAnotherSubtype() {
		XCTAssertEqual(MachOInspector.inspect(image(subtype: 0x8000_0002)).architectures, [.arm64e])
		XCTAssertEqual(MachOInspector.inspect(image(subtype: 0)).architectures, [.arm64])
	}

	func testALibraryBuiltForAnotherPlatformIsRefused() {
		XCTAssertEqual(codes(image([buildVersion(platform: 1)])), [.wrongPlatform("macOS")])
		XCTAssertEqual(codes(image([buildVersion(platform: 7)])), [.wrongPlatform("iOS Simulator")])
	}

	func testAnEncryptedLibraryIsRefused() {
		XCTAssertEqual(codes(image([encryption(cryptID: 1)])), [.encrypted])
		XCTAssertEqual(codes(image([encryption(cryptID: 0)])), [])
	}

	func testARequiredLibraryOutsideTheSandboxIsRefusedWhateverItsRoot() {
		for path in [
			"/Library/Frameworks/Cephei.framework/Cephei",
			"/var/jb/Library/Frameworks/Cephei.framework/Cephei",
			"/usr/lib/libhooker.dylib",
			"/var/jb/usr/lib/libroothide.dylib",
			"/usr/local/lib/libcustom.dylib",
			"relative/libcustom.dylib"
		] {
			XCTAssertEqual(codes(image([load(path)])), [.requiresPathOutsideSandbox(path)], path)
		}
	}

	func testAReexportedLibraryOutsideTheSandboxIsRefusedToo() {
		let path = "/Library/Frameworks/Cephei.framework/Cephei"
		XCTAssertEqual(codes(image([load(path, command: 0x8000_001f)])), [.requiresPathOutsideSandbox(path)])
	}

	func testAWeakLibraryOutsideTheSandboxIsOnlyReported() {
		let path = "/var/jb/usr/lib/libcolorpicker.dylib"
		let findings = TweakCompatibility.evaluate(binary: MachOInspector.inspect(image([load(path, command: 0x8000_0018)])))

		XCTAssertEqual(findings.map(\.code), [.optionalPathOutsideSandbox(path)])
		XCTAssertFalse(findings.contains(where: \.isBlocking))
	}

	func testEachProblemPathIsReportedOnce() {
		let path = "/Library/Frameworks/Cephei.framework/Cephei"
		XCTAssertEqual(
			codes(image([load(path), load(path, command: 0x8000_0018)])),
			[.requiresPathOutsideSandbox(path)]
		)
	}

	func testDamagedLoadCommandsAreRefusedBecauseTheListCannotBeTrusted() {
		var data = image([load("/usr/lib/libobjc.A.dylib")])
		// The command now claims more bytes than the image holds.
		data.replaceSubrange(36..<40, with: word(0x4000))
		XCTAssertTrue(codes(data).contains(.malformedLoadCommands))
	}

	func testTheRejectionNamesTheFileAndOnlyTheBlockingReasons() throws {
		let path = "/Library/Frameworks/Cephei.framework/Cephei"
		let weak = "/var/jb/usr/lib/libcolorpicker.dylib"
		let findings = TweakCompatibility.evaluate(
			binary: MachOInspector.inspect(image([load(path), load(weak, command: 0x8000_0018)]))
		)
		let description = try XCTUnwrap(
			TweakCompatibility.Rejected(fileName: "Tweak.dylib", findings: findings).errorDescription
		)

		XCTAssertTrue(description.contains("Tweak.dylib"))
		XCTAssertTrue(description.contains(path))
		XCTAssertFalse(description.contains(weak))
	}

	// MARK: - Load path classes

	func testSystemDirectoriesAreSystemExceptForLibrariesAJailbreakPutsThere() {
		XCTAssertEqual(TweakCompatibility.classify(loadPath: "/usr/lib/libz.1.dylib"), .system)
		XCTAssertEqual(TweakCompatibility.classify(loadPath: "/System/Library/PrivateFrameworks/X.framework/X"), .system)
		XCTAssertEqual(TweakCompatibility.classify(loadPath: "/usr/lib/libsubstitute.dylib"), .outsideSandbox)
		XCTAssertEqual(TweakCompatibility.classify(loadPath: "/usr/lib/libsubstrate.dylib"), .hookRuntime)
	}

	// MARK: - Package layout

	func testTheArchitectureFieldNamesTheLayout() {
		XCTAssertEqual(TweakPackageLayout(declaredArchitecture: "iphoneos-arm"), .rootful)
		XCTAssertEqual(TweakPackageLayout(declaredArchitecture: " iphoneos-arm64\n"), .rootless)
		XCTAssertEqual(TweakPackageLayout(declaredArchitecture: "IPHONEOS-ARM64E"), .roothide)
		XCTAssertNil(TweakPackageLayout(declaredArchitecture: "all"))
		XCTAssertNil(TweakPackageLayout(declaredArchitecture: nil))
	}

	func testARootfulPackageIsReadFromTheRoot() {
		let resolution = TweakCompatibility.resolveLayout(
			declaredArchitecture: "iphoneos-arm", hasRootPayload: true, hasRootlessPayload: false
		)
		XCTAssertEqual(resolution, .init(layout: .rootful, findings: []))
		XCTAssertEqual(resolution.layout.payloadPrefixes, [""])
	}

	func testARootlessPackageIsReadOnlyFromItsOwnTree() {
		let resolution = TweakCompatibility.resolveLayout(
			declaredArchitecture: "iphoneos-arm64", hasRootPayload: false, hasRootlessPayload: true
		)
		XCTAssertEqual(resolution, .init(layout: .rootless, findings: []))
		XCTAssertEqual(resolution.layout.payloadPrefixes, ["var/jb/"])
	}

	func testARoothidePackageIsNotMistakenForRootful() {
		let resolution = TweakCompatibility.resolveLayout(
			declaredArchitecture: "iphoneos-arm64e", hasRootPayload: true, hasRootlessPayload: false
		)
		XCTAssertEqual(resolution.layout, .roothide)
		XCTAssertEqual(resolution.findings.map(\.code), [.roothidePackage])
		XCTAssertFalse(resolution.isBlocked)
	}

	func testAPackageWithBothTreesIsRefusedAndReadFromNeither() {
		for architecture in ["iphoneos-arm", "iphoneos-arm64", "iphoneos-arm64e", nil] {
			let resolution = TweakCompatibility.resolveLayout(
				declaredArchitecture: architecture, hasRootPayload: true, hasRootlessPayload: true
			)
			XCTAssertEqual(resolution.layout, .mixed)
			XCTAssertTrue(resolution.isBlocked)
			XCTAssertEqual(resolution.layout.payloadPrefixes, [])
		}
	}

	func testTheFilesDecideWhenTheDeclarationDisagrees() {
		let legacyRootless = TweakCompatibility.resolveLayout(
			declaredArchitecture: "iphoneos-arm", hasRootPayload: false, hasRootlessPayload: true
		)
		XCTAssertEqual(legacyRootless.layout, .rootless)
		XCTAssertEqual(legacyRootless.findings.map(\.code), [.layoutMismatch(declared: .rootful, observed: .rootless)])
		XCTAssertFalse(legacyRootless.isBlocked)

		let mislabelled = TweakCompatibility.resolveLayout(
			declaredArchitecture: "iphoneos-arm64", hasRootPayload: true, hasRootlessPayload: false
		)
		XCTAssertEqual(mislabelled.layout, .rootful)
		XCTAssertEqual(mislabelled.findings.map(\.code), [.layoutMismatch(declared: .rootless, observed: .rootful)])
	}

	func testAPackageWithoutPayloadKeepsItsDeclarationOrStaysUnknown() {
		XCTAssertEqual(
			TweakCompatibility.resolveLayout(declaredArchitecture: "iphoneos-arm64", hasRootPayload: false, hasRootlessPayload: false).layout,
			.rootless
		)
		XCTAssertEqual(
			TweakCompatibility.resolveLayout(declaredArchitecture: nil, hasRootPayload: false, hasRootlessPayload: false).layout,
			.unknown
		)
	}

	func testPayloadPresenceLooksOnlyWhereInjectionReads() {
		var presence = TweakCompatibility.payloadPresence(inRelativePaths: [
			"/Library/MobileSubstrate/DynamicLibraries/Tweak.dylib"
		])
		XCTAssertTrue(presence.root)
		XCTAssertFalse(presence.rootless)

		presence = TweakCompatibility.payloadPresence(inRelativePaths: [
			"./var/jb/Library/Frameworks/Helper.framework",
			"/var/jb/usr/lib/libhelper.dylib"
		])
		XCTAssertFalse(presence.root)
		XCTAssertTrue(presence.rootless)

		// A library outside the injected directories is not payload in either tree.
		presence = TweakCompatibility.payloadPresence(inRelativePaths: ["/usr/lib/libhelper.dylib"])
		XCTAssertFalse(presence.root)
		XCTAssertFalse(presence.rootless)
	}

	// MARK: - Package dependencies

	func testDependsFieldIsSplitIntoNamesWithoutVersionsOrQualifiers() {
		XCTAssertEqual(
			TweakCompatibility.dependencyGroups(fromDependsField: "mobilesubstrate (>= 0.9.5000), com.example.lib:any , Firmware (>= 14.0)"),
			[["mobilesubstrate"], ["com.example.lib"], ["firmware"]]
		)
		XCTAssertEqual(TweakCompatibility.dependencyGroups(fromDependsField: nil), [])
		XCTAssertEqual(TweakCompatibility.dependencyGroups(fromDependsField: " , ,"), [])
	}

	func testTheJailbreakAndTheHookRuntimeAreNotReportedAsMissing() {
		XCTAssertEqual(
			TweakCompatibility.unmetDependencies(dependsField: "mobilesubstrate, firmware (>= 15.0), ellekit, preferenceloader"),
			[]
		)
	}

	func testALibraryPackageThatIsNotInjectedIsReported() {
		XCTAssertEqual(
			TweakCompatibility.unmetDependencies(dependsField: "mobilesubstrate, com.example.libfoo (>= 1.0), com.example.libbar"),
			["com.example.libfoo", "com.example.libbar"]
		)
	}

	func testAPackageInjectedInTheSameRunSatisfiesTheDependency() {
		XCTAssertEqual(
			TweakCompatibility.unmetDependencies(
				dependsField: "com.example.libfoo, com.example.libbar",
				available: ["com.example.LibFoo"]
			),
			["com.example.libbar"]
		)
	}

	func testAnyAlternativeSatisfiesAGroup() {
		XCTAssertEqual(TweakCompatibility.unmetDependencies(dependsField: "com.example.a | mobilesubstrate"), [])
		XCTAssertEqual(
			TweakCompatibility.unmetDependencies(dependsField: "com.example.a | com.example.b", available: ["com.example.b"]),
			[]
		)
		XCTAssertEqual(TweakCompatibility.unmetDependencies(dependsField: "com.example.a | com.example.b"), ["com.example.a"])
	}

	func testUnmetDependenciesAreAdvisoryAndTheNewFailuresBlock() {
		XCTAssertFalse(TweakCompatibility.Finding(code: .unmetDependencies(["x"])).isBlocking)
		XCTAssertTrue(TweakCompatibility.Finding(code: .hookRuntimeUnavailable).isBlocking)
		XCTAssertTrue(TweakCompatibility.Finding(code: .hookRuntimeNotRedirected("/usr/lib/libsubstrate.dylib")).isBlocking)
		XCTAssertTrue(TweakCompatibility.Finding(code: .loadCommandNotAdded).isBlocking)
	}
}
