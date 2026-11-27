// MARK: - Catalog download resolution
//
// Turns a selected catalog release into a request for the existing download
// manager. The URL comes from the selected release only; no redirect, scheme or
// metadata field can introduce a local path or a script.

import Foundation
import NimbleExtensions

struct CatalogDownloadRequest: Equatable, Sendable {
    let url: URL
    let appName: String
    let appDescription: String?
    let sourceID: String
    let bundleIdentifier: String
    let version: String
    let expectation: CatalogDownloadExpectation
    let integrityVerified: Bool
}

enum CatalogDownloadResolverError: LocalizedError, Equatable {
    case noRelease
    case invalidURL(String)
    case sizeLimit

    var errorDescription: String? {
        switch self {
        case .noRelease: .localized("This app has no downloadable release.")
        case .invalidURL(let detail): String.localized("The selected release has an unusable download URL: %@", arguments: detail)
        case .sizeLimit: .localized("The selected release exceeds the download size limit.")
        }
    }
}

enum CatalogDownloadResolver {
    static func resolve(app: CatalogAppRecord, release: CatalogRelease? = nil, integrityVerified: Bool = false) throws -> CatalogDownloadRequest {
        guard let release = release ?? app.latest else { throw CatalogDownloadResolverError.noRelease }
        guard let url = URL(string: release.downloadURL) else {
            throw CatalogDownloadResolverError.invalidURL(release.downloadURL)
        }
        do { try PackageDownloadURLPolicy.validateInitialURL(url) }
        catch { throw CatalogDownloadResolverError.invalidURL(error.localizedDescription) }
        if let size = release.size, TransferAcceptancePolicy.transferExceedsPackageLimit(
            expectedBytes: size, receivedBytes: 0
        ) {
            throw CatalogDownloadResolverError.sizeLimit
        }
        return CatalogDownloadRequest(
            url: url,
            appName: app.name,
            appDescription: app.description ?? app.summary,
            sourceID: app.sourceID,
            bundleIdentifier: app.bundleIdentifier,
            version: release.version,
            expectation: app.currentIntegrity,
            integrityVerified: integrityVerified
        )
    }
}
