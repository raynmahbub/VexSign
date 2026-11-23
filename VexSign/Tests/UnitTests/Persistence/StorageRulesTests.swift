//
//  StorageRulesTests.swift
//  VexSignTests
//
//  The cleanup rules are two UserDefaults keys plus the comparison that decides
//  whether the launch-time check shows a warning. The comparison is now a pure
//  function precisely so it can be tested without walking Documents.
//

import XCTest
@testable import VexSign

final class StorageRulesTests: XCTestCase {

	private var defaults: UserDefaults { .standard }
	private var savedKeep: Any?
	private var savedWarn: Any?

	override func setUp() {
		super.setUp()
		savedKeep = defaults.object(forKey: StorageRules.keepOnlyLatestKey)
		savedWarn = defaults.object(forKey: StorageRules.warnGigabytesKey)
	}

	override func tearDown() {
		restore(savedKeep, key: StorageRules.keepOnlyLatestKey)
		restore(savedWarn, key: StorageRules.warnGigabytesKey)
		super.tearDown()
	}

	private func restore(_ value: Any?, key: String) {
		if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
	}

	func testWarningRuleIsOffByDefault() {
		defaults.removeObject(forKey: StorageRules.warnGigabytesKey)
		XCTAssertEqual(StorageRules.warnGigabytes, 0)
		XCTAssertFalse(StorageRules.isOverLimit(used: .max, gigabytes: 0),
		               "0 GB means the rule is off, not 'warn about everything'")
	}

	func testThresholdIsExclusiveAndCountsDecimalGigabytes() {
		XCTAssertFalse(StorageRules.isOverLimit(used: 1_000_000_000, gigabytes: 1), "exactly at the limit is not over it")
		XCTAssertTrue(StorageRules.isOverLimit(used: 1_000_000_001, gigabytes: 1))
		// 1 GiB is 1.07 GB, so it is already past a 1 GB limit: the unit is the one
		// Settings shows (10^9), not GiB.
		XCTAssertTrue(StorageRules.isOverLimit(used: 1_073_741_824, gigabytes: 1))
	}

	func testNegativeThresholdDisablesTheRule() {
		XCTAssertFalse(StorageRules.isOverLimit(used: .max, gigabytes: -1),
		               "a corrupt default must not produce a warning on every launch")
	}

	func testSettingRoundTripsThroughUserDefaults() {
		StorageRules.keepOnlyLatestSigned = true
		XCTAssertTrue(StorageRules.keepOnlyLatestSigned)
		StorageRules.warnGigabytes = 5
		XCTAssertEqual(StorageRules.warnGigabytes, 5)
		StorageRules.warnGigabytes = 0
		XCTAssertEqual(StorageRules.warnGigabytes, 0, "turning the warning off must persist as 0")
	}

	func testAWronglyTypedDefaultReadsAsOff() {
		defaults.set("eight", forKey: StorageRules.warnGigabytesKey)
		XCTAssertEqual(StorageRules.warnGigabytes, 0)
	}
}
