//
//  CloudUploadBodyTests.swift
//  VexSignTests
//
//  The cloud upload request, checked against the contract the service documents.
//
//  `Services/CloudSigning/cloud-signing/README.md` and `Services/CloudSigning/cloud-signing/openapi.json` describe
//  `POST /api/upload?kind=ipa|p12|provision` with **exactly one** multipart file and a
//  `201 {id,kind,bytes,sha256}`. The app used to send `kind` as a form field, read the whole
//  archive into memory twice, and decode `{id,key,size}` — wrong in three independent ways, none
//  of which the type system could catch. These tests pin the shape, the streaming copy and the
//  header-injection guard.
//

import Foundation
import XCTest
@testable import VexSign

final class CloudUploadBodyTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("cloud-upload-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let directory { try? FileManager.default.removeItem(at: directory) }
	}

	// MARK: - Helpers

	private func source(_ data: Data, name: String = "Example.ipa") throws -> URL {
		let url = directory.appendingPathComponent(name)
		try data.write(to: url)
		return url
	}

	/// Builds a body for `file` and returns the bytes on disk plus the count the writer reported.
	private func build(
		_ file: URL,
		boundary: String = "BOUNDARY",
		filename: String? = nil
	) throws -> (data: Data, written: Int64) {
		let destination = directory.appendingPathComponent("body-\(UUID().uuidString)")
		let written = try CloudUploadBody.write(
			file: file,
			filename: filename ?? file.lastPathComponent,
			boundary: boundary,
			to: destination
		)
		let data = try Data(contentsOf: destination)
		try FileManager.default.removeItem(at: destination)
		return (data, written)
	}

	// MARK: - Shape

	func testTheBodyIsOneFilePartInTheDocumentedShape() throws {
		let payload = Data("payload".utf8)
		let built = try build(try source(payload), boundary: "B", filename: "Example.ipa")

		let expected = Data((
			"--B\r\n"
				+ "Content-Disposition: form-data; name=\"file\"; filename=\"Example.ipa\"\r\n"
				+ "Content-Type: application/octet-stream\r\n"
				+ "\r\n"
		).utf8) + payload + Data("\r\n--B--\r\n".utf8)

		XCTAssertEqual(built.data, expected)
		XCTAssertEqual(built.written, Int64(expected.count), "the reported size has to be what landed on disk")
	}

	func testTheBodyCarriesNoKindField() throws {
		// `kind` is a query parameter on the service. Sent as a form field it either fails the
		// strict multipart schema or is silently ignored, so it must not be here at all.
		let built = try build(try source(Data("x".utf8)))
		let text = String(decoding: built.data, as: UTF8.self)

		XCTAssertFalse(text.contains("name=\"kind\""))
		XCTAssertEqual(
			text.components(separatedBy: "Content-Disposition").count - 1,
			1,
			"exactly one part, which is the file"
		)
	}

	func testAnEmptyFileStillProducesAValidPart() throws {
		let built = try build(try source(Data()), boundary: "B", filename: "Empty.ipa")
		let text = String(decoding: built.data, as: UTF8.self)

		XCTAssertTrue(text.hasPrefix("--B\r\n"))
		XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
		XCTAssertEqual(built.written, Int64(built.data.count))
	}

	// MARK: - The archive is copied, not interpreted

	func testABinaryPayloadIsCopiedVerbatim() throws {
		var payload = Data((0..<256).map { UInt8($0) })
		// A payload that contains framing-looking bytes must not be able to confuse the parser
		// the service uses: it is copied, not escaped, and the trailer is still the last thing.
		payload.append(Data("\r\n--BOUNDARY\r\n".utf8))

		let built = try build(try source(payload))
		XCTAssertNotNil(built.data.range(of: payload), "the archive must arrive byte-identical")
		XCTAssertEqual(built.data.suffix(CloudUploadBody.trailer(boundary: "BOUNDARY").utf8.count),
					   Data(CloudUploadBody.trailer(boundary: "BOUNDARY").utf8))
	}

	func testAFileLargerThanOneChunkIsCopiedWithoutLoss() throws {
		// More than one read, so the chunked copy is actually exercised.
		let size = CloudUploadBody.chunkSize * 2 + 7
		let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

		let built = try build(try source(payload))
		let header = Data(CloudUploadBody.header(boundary: "BOUNDARY", filename: "Example.ipa").utf8)
		let trailer = Data(CloudUploadBody.trailer(boundary: "BOUNDARY").utf8)

		XCTAssertEqual(built.data.count, header.count + payload.count + trailer.count)
		let middle = built.data.dropFirst(header.count).dropLast(trailer.count)
		XCTAssertEqual(Data(middle), payload)
	}

	// MARK: - Header injection

	func testAFilenameCannotInjectAHeader() {
		let nasty = "evil\";\r\nX-Injected: 1\r\n\r\n.ipa"
		let header = CloudUploadBody.header(boundary: "B", filename: nasty)

		// The name's letters may survive — they are just a name. What must not survive is a quote
		// that closes the parameter, or a CRLF that starts a header line of the sender's choosing.
		let safe = CloudUploadBody.safeFilename(nasty)
		XCTAssertFalse(safe.contains("\""), "a quote would close the filename parameter")
		XCTAssertFalse(safe.contains("\r"))
		XCTAssertFalse(safe.contains("\n"))
		XCTAssertEqual(safe.components(separatedBy: "\r\n").count, 1, "a sanitised name is one line")
		XCTAssertEqual(
			header.components(separatedBy: "\r\n").count,
			5,
			"`--B`, disposition, content type, and the blank line that ends them: no injected line"
		)
	}

	func testAnUnusableFilenameStillNamesAFile() {
		XCTAssertEqual(CloudUploadBody.safeFilename(""), "upload.bin")
		XCTAssertEqual(CloudUploadBody.safeFilename("..."), "upload.bin")
		XCTAssertEqual(CloudUploadBody.safeFilename("   "), "upload.bin")
		XCTAssertTrue(CloudUploadBody.safeFilename(String(repeating: "a", count: 400)).count <= 120)
	}

	// MARK: - The request

	func testKindTravelsInTheQuery() throws {
		let base = try XCTUnwrap(URL(string: "https://cloud.example.com"))
		let request = try CloudUploadBody.request(base: base, kind: .ipa, apiKey: "token", boundary: "B")
		let url = try XCTUnwrap(request.url)
		let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

		XCTAssertEqual(request.httpMethod, "POST")
		XCTAssertEqual(components.queryItems, [URLQueryItem(name: "kind", value: "ipa")])
		XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
		XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
		// One credential header only. The service verifies `Authorization` and redacts it; it
		// ignores `x-api-key` and would log it.
		XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
	}

	func testABasePathIsKeptAndTheRequestCarriesNoTokenWithoutOne() throws {
		let base = try XCTUnwrap(URL(string: "https://cloud.example.com/signing"))
		let request = try CloudUploadBody.request(base: base, kind: .provision, apiKey: "", boundary: "B")

		XCTAssertEqual(request.url?.path, "/signing/api/upload")
		XCTAssertEqual(request.url?.query, "kind=provision")
		XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
		XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
	}

	// MARK: - The response the service actually sends

	func testTheDocumentedUploadResponseDecodes() throws {
		let json = #"{"id":"6f1c2f7e-0000-4000-8000-000000000000","kind":"ipa","bytes":12,"sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"}"#
		let decoded = try JSONDecoder().decode(CloudUploadResponse.self, from: Data(json.utf8))

		XCTAssertEqual(decoded.id, "6f1c2f7e-0000-4000-8000-000000000000")
		XCTAssertEqual(decoded.kind, .ipa)
		XCTAssertEqual(decoded.bytes, 12)
		XCTAssertEqual(decoded.sha256, "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
	}
}
