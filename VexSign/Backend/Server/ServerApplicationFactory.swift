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
                     bodyLimit: ByteCount, caseInsensitive: Bool) -> Application {
        // Preserve the existing synchronous server lifecycle. Vapor 4.122.3 still
        // supports it (deprecated); an async lifecycle migration is separate work.
        let app = Application(environment)
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
