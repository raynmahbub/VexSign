// AnisetteServer — a PROTOCOL MOCK for VexSign's Free Apple ID signing flow.
//
// ⚠️ This does NOT produce valid Anisette data. It returns the ten required
// header fields with FABRICATED values (a random serial, a UUID-derived hash,
// a fixed routing number) so the client/server wire format can be exercised
// locally. Apple's services will reject these headers; this server cannot be
// used to actually authenticate or provision. For a working provider, deploy a
// real Anisette implementation (for example an anisette-v3 compatible service)
// and point VexSign at it over HTTPS.
//
// Platform: macOS only. It uses Apple's Network framework, which is not
// available on Linux. Build and run with Swift 5.9+ on macOS:
//
//     swift run            # from this directory
//     PORT=9000 swift run  # override the listen port
//
// Endpoint: GET http://localhost:<port>/anisette
//
// Required header fields (10 total), returned as {"headers": { ... }}:
// - X-Apple-I-MD
// - X-Apple-I-MD-M
// - X-Apple-I-MD-RINFO
// - X-Apple-I-MD-LU
// - X-Apple-I-SRL-NO
// - X-Apple-I-Client-Time
// - X-Apple-I-Timezone
// - X-Apple-Locale
// - X-Apple-Device-ID
// - X-Mme-Device-Id

import Foundation
import Network

struct AnisetteResponse: Codable {
    let headers: [String: String]
}

actor AnisetteServer {
    private let port: UInt16
    private let deviceID: String
    private let server: HTTPServer

    init(port: UInt16 = 8080) {
        self.port = port
        self.deviceID = UUID().uuidString.uppercased()
        self.server = HTTPServer(port: port)
    }

    func start() async throws {
        try await server.start { request in
            await self.handleRequest(request)
        }
    }

    private func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // Only accept GET requests to /anisette.
        guard request.method == "GET", request.path == "/anisette" else {
            return HTTPResponse(status: 404, body: "Not Found")
        }

        let response = AnisetteResponse(headers: generateAnisetteHeaders())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(response)
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch {
            return HTTPResponse(status: 500, body: "Encoding failed: \(error)")
        }
    }

    private func generateAnisetteHeaders() -> [String: String] {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let clientTime = formatter.string(from: now)

        let timezone = TimeZone.current.identifier
        let locale = Locale.current.identifier

        // FABRICATED identifiers for wire-format testing only. A real provider
        // derives these from Apple's algorithm and a provisioned machine identity.
        let deviceIDHash = Data(deviceID.utf8).base64EncodedString()
        let md = String(deviceIDHash.prefix(32))
        let mdM = String(deviceIDHash.suffix(32))

        return [
            "X-Apple-I-MD": md,
            "X-Apple-I-MD-M": mdM,
            "X-Apple-I-MD-RINFO": "1710000000",
            "X-Apple-I-MD-LU": "\(Int(now.timeIntervalSince1970))",
            "X-Apple-I-SRL-NO": "\(Int.random(in: 100000...999999))",
            "X-Apple-I-Client-Time": clientTime,
            "X-Apple-I-Timezone": timezone,
            "X-Apple-Locale": locale,
            "X-Apple-Device-ID": deviceID,
            "X-Mme-Device-Id": deviceID
        ]
    }
}

// Simple HTTP server implementation (macOS / Network framework).
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data?

    init(status: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    init(status: Int, body: String) {
        self.status = status
        self.headers = ["Content-Type": "text/plain"]
        self.body = Data(body.utf8)
    }
}

actor HTTPServer {
    private let port: UInt16
    private var listener: NWListener?

    init(port: UInt16) {
        self.port = port
    }

    func start(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: endpointPort)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Mock Anisette server listening on port \(self.port)")
            case .failed(let error):
                print("Server failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            Task {
                await self.handleConnection(connection, handler: handler)
            }
        }

        listener.start(queue: .main)

        // Keep the server running until the task is cancelled.
        try await Task.sleep(nanoseconds: UInt64.max)
    }

    private func handleConnection(_ connection: NWConnection, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) async {
        connection.start(queue: .main)

        do {
            let requestData = try await readData(from: connection)
            let request = parseRequest(requestData)
            let response = await handler(request)
            try await writeResponse(response, to: connection)
        } catch {
            print("Connection error: \(error)")
        }

        connection.cancel()
    }

    private func readData(from connection: NWConnection) async throws -> Data {
        var data = Data()
        let separator = Data("\r\n\r\n".utf8)

        while true {
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let content = content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }

            if let chunk = chunk {
                data.append(chunk)
                if data.range(of: separator) != nil {
                    break
                }
            } else {
                break
            }
        }

        return data
    }

    private func parseRequest(_ data: Data) -> HTTPRequest {
        let string = String(data: data, encoding: .utf8) ?? ""
        let lines = string.components(separatedBy: "\r\n")

        guard let firstLine = lines.first else {
            return HTTPRequest(method: "", path: "", headers: [:], body: nil)
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return HTTPRequest(method: "", path: "", headers: [:], body: nil)
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        var bodyStart = 0

        for (index, line) in lines.dropFirst().enumerated() {
            if line.isEmpty {
                bodyStart = index + 2
                break
            }
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                headers[String(headerParts[0]).lowercased()] = String(headerParts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        let bodyData: Data?
        if bodyStart < lines.count {
            let bodyString = lines[bodyStart...].joined(separator: "\r\n")
            bodyData = Data(bodyString.utf8)
        } else {
            bodyData = nil
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    private func writeResponse(_ response: HTTPResponse, to connection: NWConnection) async throws {
        var responseString = "HTTP/1.1 \(response.status)\r\n"

        for (key, value) in response.headers {
            responseString += "\(key): \(value)\r\n"
        }

        if let body = response.body {
            responseString += "Content-Length: \(body.count)\r\n"
        }

        responseString += "\r\n"

        var responseData = Data(responseString.utf8)
        if let body = response.body {
            responseData.append(body)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: responseData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

// Main entry point.
@main
struct AnisetteServerMain {
    static func main() async {
        let port = UInt16(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
        print("Starting PROTOCOL MOCK Anisette server (fabricated headers; not valid for Apple).")
        let server = AnisetteServer(port: port)

        do {
            try await server.start()
        } catch {
            print("Server error: \(error)")
            exit(1)
        }
    }
}
