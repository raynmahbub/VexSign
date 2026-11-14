import Foundation
import XCTest
import SideSign
@testable import NativeSigningLinkSmoke

final class HTTPSAnisetteProviderTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private actor Probe {
        var requests = 0
        var lastEndpoint: URL?
        var lastLimit: Int?
        func record(_ endpoint: URL, _ limit: Int) { requests += 1; lastEndpoint = endpoint; lastLimit = limit }
        func count() -> Int { requests }
    }
    private struct Transport: AnisetteHeaderTransport {
        let response: AnisetteHeaderResponse
        let failure: Bool
        let probe: Probe
        func fetch(from endpoint: URL, maximumBytes: Int) async throws -> AnisetteHeaderResponse {
            await probe.record(endpoint, maximumBytes)
            if failure { throw NSError(domain: "SECRET-RESPONSE", code: 1) }
            return response
        }
    }
    private func descriptor() throws -> AnisetteProviderDescriptor {
        let endpoint = try XCTUnwrap(URL(string: "https://provider.example.invalid/headers"))
        return try AnisetteProviderDescriptor(identifier: "fixture", displayName: "Fixture", policyRevision: "header-json-v1", endpoint: endpoint)
    }
    private func fields(at suppliedDate: Date? = nil) -> [String: String] {
        let date = suppliedDate ?? Self.now
        let formatter = ISO8601DateFormatter()
        return [
            "X-Apple-I-MD-M": Data("synthetic-machine".utf8).base64EncodedString(),
            "X-Apple-I-MD": Data("synthetic-otp".utf8).base64EncodedString(),
            "X-Apple-I-MD-LU": "synthetic-local-id", "X-Apple-I-MD-RINFO": "17106176",
            "X-Mme-Device-Id": "12345678-1234-1234-1234-123456789ABC", "X-Apple-I-SRL-NO": "0",
            "X-MMe-Client-Info": "synthetic-client", "User-Agent": "synthetic-agent",
            "X-Apple-I-Client-Time": formatter.string(from: date), "X-Apple-Locale": "en_US", "X-Apple-I-TimeZone": "UTC"
        ]
    }
    private func provider(body: Data? = nil, status: Int = 200, mime: String? = "application/json", url: URL? = nil,
                          failure: Bool = false, probe: Probe = Probe()) throws -> HTTPSAnisetteProvider<Transport> {
        let descriptor = try descriptor()
        let endpoint = try XCTUnwrap(descriptor.endpoint)
        let data = try body ?? JSONEncoder().encode(fields())
        let response = AnisetteHeaderResponse(url: url ?? endpoint, status: status, mimeType: mime, body: data)
        return try HTTPSAnisetteProvider(descriptor: descriptor, transport: Transport(response: response, failure: failure, probe: probe), clock: { Self.now })
    }

    func testValidHeaderJSONBuildsSDKHeaders() async throws {
        let provider = try provider()
        let result = try await provider.freshHeaders()
        XCTAssertEqual(result.deviceID, "12345678-1234-1234-1234-123456789ABC")
        XCTAssertEqual(result.routingInfo, "17106176")
        XCTAssertEqual(result.oneTimePassword, Data("synthetic-otp".utf8).base64EncodedString())
    }

    func testCaseInsensitiveHeaderNamesAreAccepted() async throws {
        let lowercase = Dictionary(uniqueKeysWithValues: fields().map { ($0.key.lowercased(), $0.value) })
        let provider = try provider(body: JSONEncoder().encode(lowercase))
        let result = try await provider.freshHeaders()
        XCTAssertEqual(result.locale, "en_US")
    }

    func testMissingUnknownAndCaseDuplicateHeadersAreRejected() async throws {
        var missing = fields(); missing.removeValue(forKey: "X-Apple-I-MD")
        var unknown = fields(); unknown["server-version"] = "1"
        var duplicate = fields(); duplicate["x-apple-i-md"] = duplicate["X-Apple-I-MD"]
        for values in [missing, unknown, duplicate] {
            let provider = try provider(body: JSONEncoder().encode(values))
            do { _ = try await provider.freshHeaders(); XCTFail("Reject invalid schema") }
            catch { XCTAssertEqual(error as? HTTPSAnisetteProviderError, .invalidResponse) }
        }
    }

    func testExactAndEscapedDuplicateJSONKeysAreRejected() async throws {
        let encoded = try JSONEncoder().encode(fields())
        let completeObject = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let value = Data("synthetic-otp".utf8).base64EncodedString()
        for key in ["X-Apple-I-MD", "X-\\u0041pple-I-MD"] {
            // Without duplicate detection each is an otherwise valid eleven-key
            // response after conventional dictionary decoding drops duplicates.
            let text = String(completeObject.dropLast()) + ",\"" + key + "\":\"" + value + "\"}"
            let provider = try provider(body: Data(text.utf8))
            do { _ = try await provider.freshHeaders(); XCTFail("Do not discard duplicate keys") }
            catch { XCTAssertEqual(error as? HTTPSAnisetteProviderError, .invalidResponse) }
        }
    }

    func testNonObjectNonStringTrailingAndNestedJSONAreRejected() async throws {
        for text in ["[]", "null", "{} trailing", "{\"x\":12}", "{\"x\":{}}", "{\"x\":\"value\",}", "{\"x\":\"\\q\"}"] {
            let provider = try provider(body: Data(text.utf8))
            do { _ = try await provider.freshHeaders(); XCTFail("Reject malformed header payload") }
            catch { XCTAssertEqual(error as? HTTPSAnisetteProviderError, .invalidResponse) }
        }
    }

    func testHTTPStatusContentTypeAndChangedURLAreRejected() async throws {
        let cases: [(Int, String?, HTTPSAnisetteProviderError)] = [(302, "application/json", .httpStatus(302)),
            (503, "application/json", .httpStatus(503)), (200, "text/html", .invalidContentType), (200, nil, .invalidContentType)]
        for (status, mime, expected) in cases {
            let provider = try provider(status: status, mime: mime)
            do { _ = try await provider.freshHeaders(); XCTFail("Reject response metadata") }
            catch { XCTAssertEqual(error as? HTTPSAnisetteProviderError, expected) }
        }
        let changedURL = try XCTUnwrap(URL(string: "https://other.example.invalid/headers"))
        let changed = try provider(url: changedURL)
        do { _ = try await changed.freshHeaders(); XCTFail("Reject a redirected/mismatched URL") }
        catch { XCTAssertEqual(error as? HTTPSAnisetteProviderError, .invalidResponse) }
    }

    func testEmptyAndOversizedBodyAreRejected() async throws {
        for data in [Data(), Data(repeating: 32, count: 64 * 1024 + 1)] {
            let provider = try provider(body: data)
            do { _ = try await provider.freshHeaders(); XCTFail("Reject body size") }
            catch { XCTAssertNotNil(error as? HTTPSAnisetteProviderError) }
        }
    }

    func testOldFutureAndInvalidClientTimestampsAreRejected() async throws {
        for date in [Self.now.addingTimeInterval(-301), Self.now.addingTimeInterval(301)] {
            let provider = try provider(body: JSONEncoder().encode(fields(at: date)))
            do { _ = try await provider.freshHeaders(); XCTFail("Reject timestamp outside skew bound") }
            catch { XCTAssertEqual(error as? HTTPSAnisetteProviderError, .staleResponse) }
        }
        var values = fields(); values["X-Apple-I-Client-Time"] = "not-a-date"
        let invalid = try provider(body: JSONEncoder().encode(values))
        do { _ = try await invalid.freshHeaders(); XCTFail("Reject invalid time") }
        catch { XCTAssertEqual(error as? HTTPSAnisetteProviderError, .staleResponse) }
    }

    func testHeaderInjectionInvalidBase64UUIDAndRoutingAreRejected() async throws {
        for (key, value) in [("User-Agent", "agent\r\nCookie: injected"), ("X-Apple-I-MD", "!not-base64!"),
                             ("X-Mme-Device-Id", "invalid"), ("X-Apple-I-MD-RINFO", "not-digits")] {
            var values = fields(); values[key] = value
            let provider = try provider(body: JSONEncoder().encode(values))
            do { _ = try await provider.freshHeaders(); XCTFail("Reject invalid field") }
            catch { XCTAssertEqual(error as? HTTPSAnisetteProviderError, .invalidResponse) }
        }
    }

    func testCancelledRequestDoesNotReachTransport() async throws {
        let probe = Probe()
        let provider = try provider(probe: probe)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.freshHeaders()
        }
        do { _ = try await task.value; XCTFail("Cancelled task must not request headers") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await probe.count()
        XCTAssertEqual(count, 0)
    }

    func testRawTransportErrorDoesNotEscape() async throws {
        let provider = try provider(failure: true)
        do { _ = try await provider.freshHeaders(); XCTFail("Transport failure must propagate safely") }
        catch {
            XCTAssertEqual(error as? HTTPSAnisetteProviderError, .invalidResponse)
            XCTAssertFalse(String(describing: error).contains("SECRET"))
        }
    }

    func testLocalDescriptorIsNotSilentlyReplacedWithRemoteServer() throws {
        let descriptor = try AnisetteProviderDescriptor(identifier: "local", displayName: "Local", policyRevision: "1", endpoint: nil)
        let response = AnisetteHeaderResponse(url: URL(fileURLWithPath: "/"), status: 200, mimeType: nil, body: Data())
        XCTAssertThrowsError(try HTTPSAnisetteProvider(descriptor: descriptor, transport: Transport(response: response, failure: false, probe: Probe()))) {
            XCTAssertEqual($0 as? HTTPSAnisetteProviderError, .remoteEndpointRequired)
        }
    }
}
