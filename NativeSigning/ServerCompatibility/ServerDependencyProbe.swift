import Foundation
import Vapor
import Crypto
import SwiftASN1

/// Exported function forces the Vapor application configuration and Crypto API
/// into the same dynamic library. Construction does not bind sockets or log in.
public enum ServerDependencyProbe {
    public static func makeHTTPApplication(port: Int) -> Application {
        ServerApplicationFactory.make(environment: .testing, threads: 1,
            hostname: "localhost", bindHost: "127.0.0.1", port: port,
            transport: .http, bodyLimit: "128mb", caseInsensitive: false)
    }

    public static func digest(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(bytes)))
    }
}
