//
//  StubHTTPProtocol.swift
//  VexSignTests
//
//  One canned answer for every request, so a transport can be exercised without a
//  network. `body` and `status` are set by the test before it starts a session and read
//  by the protocol on its own queue.
//

import Foundation

final class StubHTTPProtocol: URLProtocol {
	static var body = Data()
	static var status = 200

	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard
			let url = request.url,
			let response = HTTPURLResponse(
				url: url,
				statusCode: Self.status,
				httpVersion: "HTTP/1.1",
				headerFields: ["Content-Length": String(Self.body.count)]
			)
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}

		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Self.body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}

	static func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubHTTPProtocol.self]
		return URLSession(configuration: configuration)
	}
}
