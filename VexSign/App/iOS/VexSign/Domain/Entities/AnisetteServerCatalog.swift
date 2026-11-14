import Foundation

/// Reference data only: catalogue membership is neither trust nor protocol compatibility.
struct AnisetteServerCatalog: Decodable {
    struct Server: Decodable, Identifiable {
        let name: String
        let address: String
        let kind: Int
        var id: String { address }
        var secureEndpoint: URL? {
            guard let url = URL(string: address), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { return nil }
            return url
        }
    }
    let servers: [Server]
    let sourceRepository: String
    let sourceRevision: String
    let reviewedAt: String
}
