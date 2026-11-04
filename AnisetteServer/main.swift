// AnisetteServer - A minimal HTTP server that provides Apple Anisette headers
// for VexSign's Free Apple ID signing flow.
//
// This server implements the required endpoint that returns 10 Apple headers
// as JSON, which VexSign uses for authenticating with Apple's services.
//
// Deployment: This can be run on any server with Swift 5.9+ (Linux/macOS).
// For production, use a proper web framework like Vapor or Hummingbird.
//
// Required headers (10 total):
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

struct AnisetteResponse: Codable {
    let headers: [String: String]
}

actor AnisetteServer {
    private let port: UInt16
    private let deviceID: String
    private let server: HTTPServer?

    init(port: UInt16 = 8080) {
        self.port = port
        self.deviceID = UUID().uuidString.uppercased()
        self.server = HTTPServer(port: port)
    }

    func start() async throws {
        guard let server = server else { return }
        try await server.start { request in
            return await self.handleRequest(request)
        }
        print("Anisette Server started on port \(port)")
        print("Endpoint: http://localhost:\(port)/anisette")
    }

    private func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // Only accept GET requests to /anisette
        guard request.method == "GET", request.path == "/anisette" else {
            return HTTPResponse(status: 404, body: "Not Found")
        }

        // Generate the 10 required Apple headers
        let headers = generateAnisetteHeaders()

        let response = AnisetteResponse(headers: headers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(response)

        return HTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }

    private func generateAnisetteHeaders() -> [String: String] {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let clientTime = formatter.string(from: now)

        let timezone = TimeZone.current.identifier
        let locale = Locale.current.identifier

        // Generate MD5-based identifiers (simplified - real implementation uses Apple's algorithm)
        let deviceIDHash = deviceID.data(using: .utf8)!.base64EncodedString()
        let md = "\(deviceIDHash.prefix(32))"
        let mdM = "\(deviceIDHash.suffix(32))"

        return [
            "X-Apple-I-MD": md,
            "X-Apple-I-MD-M": mdM,
            "X-Apple-I-MD-RINFO": "1710000000", // Unix timestamp
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

// Simple HTTP Server implementation
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
        self.body = body.data(using: .utf8)
    }
}

actor HTTPServer {
    private let port: UInt16
    private var listener: NWListener?

    init(port: UInt16) {
        self.port = port
    }

    func start(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Server listening on port \(self.port)")
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

        // Keep the server running
        try await Task.sleep(nanoseconds: UInt64.max)
    }

    private func handleConnection(_ connection: NWConnection, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) async {
        connection.start(queue: .main)

        do {
            // Read request
            let requestData = try await readData(from: connection)
            let request = parseRequest(requestData)

            // Handle request
            let response = await handler(request)

            // Send response
            try await writeResponse(response, to: connection)
        } catch {
            print("Connection error: \(error)")
        }

        connection.cancel()
    }

    private func readData(from connection: NWConnection) async throws -> Data {
        var data = Data()

        while true {
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let content = content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    }
                }
            }

            if let chunk = chunk {
                data.append(chunk)
                // Check if we have the full HTTP request (double CRLF)
                if data.contains("\r\n\r\n".data(using: .ascii)!) {
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
            bodyData = bodyString.data(using: .utf8)
        } else {
            bodyData = nil
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    private func writeResponse(_ response: HTTPResponse, to connection: NWConnection) async throws {
        var responseString = "HTTP/1.1 \(response.status) OK\r\n"

        for (key, value) in response.headers {
            responseString += "\(key): \(value)\r\n"
        }

        if let body = response.body {
            responseString += "Content-Length: \(body.count)\r\n"
        }

        responseString += "\r\n"

        var responseData = responseString.data(using: .utf8)!
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

// Network framework import
import Network

// Main entry point
@main
struct AnisetteServerMain {
    static func main() async {
        let port = UInt16(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
        let server = AnisetteServer(port: port)

        do {
            try await server.start()
        } catch {
            print("Server error: \(error)")
            exit(1)
        }
    }
}