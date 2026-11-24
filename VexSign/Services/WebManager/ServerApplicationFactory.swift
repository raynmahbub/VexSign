import Vapor
import NIOSSL

/// Shared by the real servers and the isolated Vapor/Crypto compatibility build.
/// Identity loading/validation stays in ServerInstaller; HTTPS cannot silently
/// turn into HTTP because an optional certificate/configuration was missing.
enum ServerApplicationFactory {
    enum Transport {
        case http
        case https(TLSConfiguration)
    }

    static func make(environment: Environment, threads: Int, hostname: String,
                     bindHost: String, port: Int, transport: Transport,
                     bodyLimit: ByteCount, caseInsensitive: Bool) async throws -> Application {
        let app = try await Application.make(environment)
        app.threadPool = .init(numberOfThreads: threads)
        switch transport {
        case .http: break
        case .https(let configuration):
            app.http.server.configuration.tlsConfiguration = configuration
        }
        app.http.server.configuration.hostname = hostname
        app.http.server.configuration.tcpNoDelay = true
        app.http.server.configuration.address = .hostname(bindHost, port: port)
        app.http.server.configuration.port = port
        app.routes.defaultMaxBodySize = bodyLimit
        app.routes.caseInsensitive = caseInsensitive
        return app
    }
}
