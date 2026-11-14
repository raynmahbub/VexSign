import Foundation

/// The common interchange subset. Unknown JSON fields survive editing/conversion.
enum RepositoryFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case altStore, sideStore, feather, esign, custom
    var id: String { rawValue }
}

indirect enum RepositoryJSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: RepositoryJSON]), array([RepositoryJSON]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: RepositoryJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([RepositoryJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct RepositoryApp: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var bundleIdentifier = ""
    var version = "1.0"
    var versionDate = ISO8601DateFormatter().string(from: Date())
    var localizedDescription = ""
    var iconURL = ""
    var screenshotURLs: [String] = []
    var downloadURL = ""
    var size: Int64 = 0
    var developerName = ""
    var category = "Other"
    var tintColor = ""
    var extra: [String: RepositoryJSON] = [:]
}

struct RepositoryDocument: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = "New Repository"
    var identifier = ""
    var iconURL = ""
    var format: RepositoryFormat = .altStore
    var apps: [RepositoryApp] = []
    var extra: [String: RepositoryJSON] = [:]
}

enum RepositoryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
