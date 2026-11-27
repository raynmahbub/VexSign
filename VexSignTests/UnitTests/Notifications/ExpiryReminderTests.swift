//
//  ExpiryReminderTests.swift
//  VexSign
//
//  Calendar-day arithmetic, individually disableable milestones, already-due
//  behaviour and stable cancellation identifiers.
//

import Foundation
import XCTest
@testable import VexSign

final class ExpiryReminderTests: XCTestCase {
    private func date(_ string: String, calendar: Calendar) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: string)!
    }

    private func subject(_ id: String = "identity-1", expiry: Date?) -> ExpiryReminderSubject {
        ExpiryReminderSubject(referenceID: id, kind: .certificate, displayName: "Team Identity", expiry: expiry)
    }

    func testCalendarDayCountIsDstSafe() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // Spring forward: only 23 hours separate these instants, but it is one calendar day.
        let now = date("2026-03-08T04:30:00Z", calendar: calendar)
        let expiry = date("2026-03-08T05:30:00Z", calendar: calendar)
        XCTAssertEqual(ExpiryReminderPlanner.daysUntil(expiry, from: now, calendar: calendar), 1)
        // The old seconds/86_400 arithmetic reported zero here.
        XCTAssertNotEqual(Int(expiry.timeIntervalSince(now) / 86_400), 1)
    }

    func testUnknownExpiryHasNoReminderAndUnknownStatus() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-01-01T00:00:00Z", calendar: calendar)
        let unknown = subject(expiry: nil)
        XCTAssertEqual(ExpiryReminderPlanner.status(for: unknown, now: now, calendar: calendar), .unknown)
        XCTAssertTrue(ExpiryReminderPlanner.plans(
            for: unknown, configuration: ExpiryReminderConfiguration(), now: now, calendar: calendar
        ).isEmpty)
    }

    func testExpiredStatusCountsWholeCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-01-10T12:00:00Z", calendar: calendar)
        let expiry = date("2026-01-08T09:00:00Z", calendar: calendar)
        XCTAssertEqual(ExpiryReminderPlanner.status(for: subject(expiry: expiry), now: now, calendar: calendar), .expired(days: 2))
    }

    func testAllMilestonesAreStableAndIndividuallyDisableable() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-01-01T00:00:00Z", calendar: calendar)
        let expiry = date("2026-02-01T00:00:00Z", calendar: calendar)
        let identity = subject(expiry: expiry)

        let all = ExpiryReminderPlanner.plans(
            for: identity, configuration: ExpiryReminderConfiguration(), now: now, calendar: calendar
        )
        XCTAssertEqual(Set(all.map(\.milestone)), Set(ExpiryMilestone.allCases))
        XCTAssertEqual(Set(all.map(\.identifier)).count, ExpiryMilestone.allCases.count)

        var configuration = ExpiryReminderConfiguration()
        configuration.set(.days14, enabled: false)
        configuration.set(.days7, enabled: false)
        let reduced = ExpiryReminderPlanner.plans(
            for: identity, configuration: configuration, now: now, calendar: calendar
        )
        XCTAssertFalse(reduced.contains { $0.milestone == .days14 })
        XCTAssertTrue(reduced.contains { $0.milestone == .days30 })
        XCTAssertEqual(ExpiryReminderPlanner.identifier(for: identity, milestone: .days30),
                       ExpiryReminderPlanner.identifier(for: identity, milestone: .days30))
    }

    func testAlreadyDuePostsOneMostUrgentReminderImmediately() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-01-20T00:00:00Z", calendar: calendar)
        let expiry = date("2026-01-18T00:00:00Z", calendar: calendar)
        let plans = ExpiryReminderPlanner.plans(
            for: subject(expiry: expiry), configuration: ExpiryReminderConfiguration(), now: now, calendar: calendar
        )
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.milestone, .expired)
        XCTAssertEqual(plans.first?.trigger, .immediate)
        XCTAssertEqual(plans.first?.notification.isTimeSensitive, true)
    }

    func testReplacementIdentifierChangesWithSubject() {
        let original = subject("identity-1", expiry: Date())
        let replaced = subject("identity-2", expiry: Date())
        XCTAssertNotEqual(
            ExpiryReminderPlanner.identifier(for: original, milestone: .days7),
            ExpiryReminderPlanner.identifier(for: replaced, milestone: .days7)
        )
    }
}
