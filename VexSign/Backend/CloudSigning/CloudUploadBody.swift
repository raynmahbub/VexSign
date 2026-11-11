//
//  CloudUploadBody.swift
//  VexSign
//
//  The request body `POST /api/upload` expects, built on disk instead of in memory.
//
//  Two things were wrong with the uploader that used this call site before:
//
//  1. It did not match the service it talks to. The contract
//     (`cloud-signing/README.md`, `cloud-signing/openapi.json`) is
//     `POST /api/upload?kind=ipa|p12|provision` with **exactly one** multipart file, and a
//     `201 {id,kind,bytes,sha256}`. The app sent `kind` as a *form field* and decoded
//     `{id,key,size}`, so a reachable cluster answered 400 to the request and the response would
//     not have decoded even if it had not.
//
//  2. It read the whole archive into `Data` twice — once with `Data(contentsOf:)` and again into
//     the concatenated body. The service accepts IPAs up to 2 GiB, so that was up to 4 GiB of
//     resident memory for one upload.
//
//  The body is now written to a temporary file a chunk at a time and handed to
//  `URLSession.upload(for:fromFile:)`, which streams it. Memory stays flat; the cost is one
//  temporary copy of the archive on disk, removed as soon as the request ends.
//

import Foundation

enum CloudUploadBody {
	/// How much of the archive is read at a time while building the body.
	static let chunkSize = 1 << 20

	/// The header the server parses, and the only place `filename` appears.
	///
	/// `filename` comes from a file the user imported, so it is sanitised: a quote, a CR or an LF
	/// in a generated header would end the quoted string or start a second header line.
	static func header(boundary: String, filename: String) -> String {
		"--\(boundary)\r\n"
			+ "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename(filename))\"\r\n"
			+ "Content-Type: application/octet-stream\r\n"
			+ "\r\n"
	}

	static func trailer(boundary: String) -> String {
		"\r\n--\(boundary)--\r\n"
	}

	static func contentType(boundary: String) -> String {
		"multipart/form-data; boundary=\(boundary)"
	}

	static func makeBoundary() -> String {
		"VexSign-\(UUID().uuidString)"
	}

	/// A filename that cannot break out of the quoted `filename` parameter.
	///
	/// Anything outside printable ASCII is replaced, as are the two characters that matter here:
	/// `"` closes the quoted string and `\` escapes it. The result is never empty, because a part
	/// without a filename is not a file part.
	static func safeFilename(_ filename: String) -> String {
		let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_. ()+,")
		var sanitised = String(filename.map { allowed.contains($0) ? $0 : "_" })
		if sanitised.count > 120 { sanitised = String(sanitised.prefix(120)) }
		// A name of only dots or spaces still names nothing useful.
		if sanitised.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty {
			sanitised = "upload.bin"
		}
		return sanitised
	}

	/// Writes the body for `file` to `destination` and returns its byte count.
	///
	/// Synchronous and `nonisolated` on purpose: it is a bulk disk copy, so the caller runs it off
	/// the main actor. It never holds more than `chunkSize` of the archive in memory.
	@discardableResult
	static func write(file: URL, filename: String, boundary: String, to destination: URL) throws -> Int64 {
		let manager = FileManager.default
		if manager.fileExists(atPath: destination.path) {
			try manager.removeItem(at: destination)
		}
		guard manager.createFile(atPath: destination.path, contents: nil) else {
			throw CocoaError(.fileWriteUnknown)
		}

		let output = try FileHandle(forWritingTo: destination)
		defer { try? output.close() } // try? ok: closing a handle we already wrote to reports nothing actionable

		var written: Int64 = 0
		func append(_ data: Data) throws {
			try output.write(contentsOf: data)
			written += Int64(data.count)
		}

		try append(Data(header(boundary: boundary, filename: filename).utf8))

		let input = try FileHandle(forReadingFrom: file)
		defer { try? input.close() } // try? ok: read-only handle; the copy's result was already decided
		while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
			try append(chunk)
		}

		try append(Data(trailer(boundary: boundary).utf8))
		return written
	}

	/// The upload request: `kind` belongs in the query string, and the token in both headers the
	/// service accepts.
	static func request(base: URL, kind: CloudArtifactKind, apiKey: String, boundary: String) throws -> URLRequest {
		var components = URLComponents(
			url: base.appendingPathComponent("api/upload"),
			resolvingAgainstBaseURL: false
		)
		components?.queryItems = [URLQueryItem(name: "kind", value: kind.rawValue)]
		guard let url = components?.url else { throw URLError(.badURL) }

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue(contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
		if !apiKey.isEmpty {
			request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
			request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		}
		return request
	}
}
