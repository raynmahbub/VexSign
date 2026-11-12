//
//  BackupVerificationTests.swift
//  VexSignTests
//
//  The backup writer used to return as soon as sealing did. This suite covers the check that now
//  stands between "the file was written" and "the backup is complete": the container is opened
//  again and must decrypt to exactly the bytes that were packed.
//
//  Fixtures are a few kilobytes of temporary files sealed with a password — no Keychain, no
//  device identity, nothing that would make the test device-bound.
//

import CryptoKit
import Foundation
import XCTest
@testable import VexSign

final class BackupVerificationTests: XCTestCase {
    private var root: URL!
    private let password = "correct horse battery"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) } // try? ok: test cleanup, nothing to report
    }

    private func write(_ bytes: Data, as name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func payload(_ count: Int = 4096) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    private func sealed(from plaintext: URL, password: String? = nil) throws -> URL {
        let output = root.appendingPathComponent("sealed-\(UUID().uuidString).vexbackup")
        try BackupCrypto.sealFile(plaintext, to: output, password: password ?? self.password)
        return output
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Digest

    func testDigestMatchesCryptoKitOverTheSameBytes() throws {
        let bytes = payload()
        let url = try write(bytes, as: "plain.zip")
        XCTAssertEqual(try BackupVerification.digest(of: url), hex(bytes))
    }

    func testDigestChangesWhenASingleByteChanges() throws {
        var bytes = payload()
        let before = try BackupVerification.digest(of: try write(bytes, as: "a.zip"))
        bytes[100] ^= 0xff
        let after = try BackupVerification.digest(of: try write(bytes, as: "b.zip"))
        XCTAssertNotEqual(before, after)
    }

    func testDigestOfAMissingFileThrows() {
        XCTAssertThrowsError(try BackupVerification.digest(of: root.appendingPathComponent("nope.zip")))
    }

    func testDigestIsStableAcrossRepeatedReads() throws {
        let url = try write(payload(200_000), as: "big.zip")
        XCTAssertEqual(try BackupVerification.digest(of: url), try BackupVerification.digest(of: url))
    }

    // MARK: - Sealed container

    func testSealedContainerVerifiesAndReportsItsSealedSize() throws {
        let plaintext = try write(payload(), as: "pack.zip")
        let expected = try BackupVerification.digest(of: plaintext)
        let file = try sealed(from: plaintext)

        let result = try BackupVerification.verifySealedContainer(
            at: file, expectedPlaintextSHA256: expected, password: password, scratch: root
        )

        XCTAssertEqual(result.plaintextSHA256, expected)
        let onDisk = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        XCTAssertEqual(result.sealedBytes, onDisk?.int64Value)
        XCTAssertGreaterThan(result.sealedBytes, 0)
    }

    func testVerificationLeavesNoScratchFileBehind() throws {
        let plaintext = try write(payload(), as: "pack.zip")
        let expected = try BackupVerification.digest(of: plaintext)
        let file = try sealed(from: plaintext)
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        _ = try BackupVerification.verifySealedContainer(
            at: file, expectedPlaintextSHA256: expected, password: password, scratch: scratch
        )

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testContainerThatDecryptsToSomethingElseIsRejected() throws {
        let plaintext = try write(payload(), as: "pack.zip")
        let file = try sealed(from: plaintext)

        XCTAssertThrowsError(try BackupVerification.verifySealedContainer(
            at: file,
            expectedPlaintextSHA256: hex(Data("something else".utf8)),
            password: password,
            scratch: root
        )) { error in
            XCTAssertEqual(error as? BackupVerification.Failure, .digestMismatch)
        }
    }

    func testWrongPasswordIsRejectedRatherThanReportedAsCorrupt() throws {
        let plaintext = try write(payload(), as: "pack.zip")
        let expected = try BackupVerification.digest(of: plaintext)
        let file = try sealed(from: plaintext)

        XCTAssertThrowsError(try BackupVerification.verifySealedContainer(
            at: file, expectedPlaintextSHA256: expected, password: "not the password", scratch: root
        ))
    }

    func testTruncatedContainerIsRejected() throws {
        let plaintext = try write(payload(64 * 1024), as: "pack.zip")
        let expected = try BackupVerification.digest(of: plaintext)
        let file = try sealed(from: plaintext)
        var bytes = try Data(contentsOf: file)
        bytes = bytes.prefix(bytes.count / 2)
        let truncated = try write(bytes, as: "truncated.vexbackup")

        XCTAssertThrowsError(try BackupVerification.verifySealedContainer(
            at: truncated, expectedPlaintextSHA256: expected, password: password, scratch: root
        ))
    }

    func testTamperedCiphertextIsRejected() throws {
        let plaintext = try write(payload(), as: "pack.zip")
        let expected = try BackupVerification.digest(of: plaintext)
        let file = try sealed(from: plaintext)
        var bytes = try Data(contentsOf: file)
        // Past the header, inside the first authenticated chunk.
        let index = min(bytes.count - 1, 128)
        bytes[index] ^= 0x01
        let tampered = try write(bytes, as: "tampered.vexbackup")

        XCTAssertThrowsError(try BackupVerification.verifySealedContainer(
            at: tampered, expectedPlaintextSHA256: expected, password: password, scratch: root
        ))
    }

    func testEmptyAndMissingContainersAreReportedAsMissing() throws {
        let empty = try write(Data(), as: "empty.vexbackup")
        XCTAssertThrowsError(try BackupVerification.verifySealedContainer(
            at: empty, expectedPlaintextSHA256: hex(Data()), password: password, scratch: root
        )) { error in
            XCTAssertEqual(error as? BackupVerification.Failure, .missingContainer)
        }

        XCTAssertThrowsError(try BackupVerification.verifySealedContainer(
            at: root.appendingPathComponent("absent.vexbackup"),
            expectedPlaintextSHA256: hex(Data()),
            password: password,
            scratch: root
        )) { error in
            XCTAssertEqual(error as? BackupVerification.Failure, .missingContainer)
        }
    }

    // MARK: - What a restore reports after it checks itself

    func testSummaryDoesNotWarnWhenNoVerificationRan() {
        var summary = BackupRestoreSummary()
        summary.record(.certificates, added: 2, skipped: 0)
        XCTAssertEqual(summary.lines.count, 1, "counts alone must not read as a failed check")
        XCTAssertEqual(summary.unverified, 2)
    }

    func testSummaryWarnsWhenVerificationFoundFewerItemsThanItAdded() {
        var summary = BackupRestoreSummary()
        summary.record(.certificates, added: 2, skipped: 0)
        summary.recordVerification(.certificates, verified: 1)
        XCTAssertEqual(summary.unverified, 1)
        XCTAssertEqual(summary.lines.count, 2)
        XCTAssertTrue(summary.lines.last?.contains("1") == true)
    }

    func testSummaryStaysSilentWhenEverythingVerified() {
        var summary = BackupRestoreSummary()
        summary.record(.sources, added: 2, skipped: 1)
        summary.recordVerification(.sources, verified: 2)
        XCTAssertEqual(summary.unverified, 0)
        XCTAssertEqual(summary.lines.count, 1)
    }

    func testVerificationCannotExceedWhatWasAdded() {
        var summary = BackupRestoreSummary()
        summary.record(.library, added: 1, skipped: 0)
        summary.recordVerification(.library, verified: 5)
        XCTAssertEqual(summary.unverified, 0)
    }

    func testADifferentPlaintextWithTheSameLengthIsStillRejected() throws {
        // The failure this guards against is a container that decrypts cleanly but holds the
        // wrong bytes — the case a size check alone would wave through.
        let plaintext = try write(payload(1024), as: "pack.zip")
        let file = try sealed(from: plaintext)
        let other = Data(repeating: 0x41, count: 1024)

        XCTAssertThrowsError(try BackupVerification.verifySealedContainer(
            at: file, expectedPlaintextSHA256: hex(other), password: password, scratch: root
        )) { error in
            XCTAssertEqual(error as? BackupVerification.Failure, .digestMismatch)
        }
    }
}
