// MARK: - Tests Runner
/// Entry point for running all unit tests.

import Foundation
import Testing

// This file ensures all test files are compiled and discoverable by Swift Testing.
// The @Suite macros in each test file automatically register the tests.

// Test modules:
// - SigningErrorMapperTests
// - NativeSigningManagerTests
// - BackgroundAutomationTests
// - DevicePickerTests
// - AnisetteProviderTests

@main
struct TestRunner {
    static func main() async {
        // Swift Testing automatically discovers and runs all @Test functions
        // in the current module when run via `swift test`
        print("VexSign Unit Tests - Run with: swift test")
    }
}