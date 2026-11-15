import SwiftUI
import UIKit
import XCTest
@testable import VexSign

/// Hosted layout coverage in the existing simulator XCTest target. This does
/// not claim real-device swipe, hit-testing, VoiceOver, or screenshot acceptance.
@MainActor
final class LibrarySwipeLayoutTests: XCTestCase {
    private func measure(width: CGFloat, open: Bool, size: DynamicTypeSize, reduceMotion: Bool) -> CGSize {
        let identity = "imported:synthetic-layout"
        let content = HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10).fill(.blue).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text("Synthetic app with a longer display name").font(.body).lineLimit(1)
                Text("1.0 · 24 MB").font(.caption).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("7 days").font(.caption).lineLimit(1)
        }
        .padding(.vertical, 8)
        .modifier(LibraryGridSwipeDelete(enabled: true, rowID: identity,
            revealedRowID: .constant(open ? identity : nil), reduceMotionRequested: reduceMotion, onDelete: {}))
        .environment(\.dynamicTypeSize, size)
        let host = UIHostingController(rootView: content)
        host.loadViewIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: 1_000))
    }

    func testCompactRevealDoesNotStretchTheRowOrChangeItsHeight() {
        let widths: [CGFloat] = [320, 393, 768]
        let sizes: [DynamicTypeSize] = [.small, .xxxLarge, .accessibility5]
        for width in widths {
            for size in sizes {
                let closed = measure(width: width, open: false, size: size, reduceMotion: false)
                let open = measure(width: width, open: true, size: size, reduceMotion: false)
                XCTAssertTrue(closed.width.isFinite && closed.height.isFinite)
                XCTAssertTrue(open.width.isFinite && open.height.isFinite)
                XCTAssertGreaterThanOrEqual(open.height, 44)
                XCTAssertLessThan(open.height, 400, "A trailing action cannot become a full-height panel.")
                XCTAssertEqual(open.height, closed.height, accuracy: 1)
                XCTAssertLessThanOrEqual(open.width, width + 1)
            }
        }
    }

    func testSystemAndCallerReducedMotionOrDisabledAnimationsAlwaysWin() {
        XCTAssertTrue(LibraryGridSwipePolicy.allowsAnimation(systemReduceMotion: false,
            requestedReduceMotion: false, animationsEnabled: true))
        for (system, requested, enabled) in [(true, false, true), (false, true, true),
                                             (true, true, true), (false, false, false)] {
            XCTAssertFalse(LibraryGridSwipePolicy.allowsAnimation(systemReduceMotion: system,
                requestedReduceMotion: requested, animationsEnabled: enabled))
        }
    }

    // SwiftUI's system environment value is read-only. Exercise the same reduced
    // motion policy via an additional request, without pretending to toggle iOS.
    func testReduceMotionHasTheSameStableLayoutAtAccessibilityTextSizes() {
        let animated = measure(width: 393, open: true, size: .accessibility5, reduceMotion: false)
        let reduced = measure(width: 393, open: true, size: .accessibility5, reduceMotion: true)
        XCTAssertEqual(animated.width, reduced.width, accuracy: 1)
        XCTAssertEqual(animated.height, reduced.height, accuracy: 1)
    }
}
