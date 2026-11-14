import Foundation
import UIKit
import CoreImage.CIFilterBuiltins

struct OTAPackage: Sendable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let downloadURL: URL
    let iconURL: URL?
}

enum OTAExporter {
    static func manifest(_ app: OTAPackage) throws -> Data {
        guard app.downloadURL.scheme == "https", RepositoryValidator.webURL(app.downloadURL.absoluteString) != nil,
              !app.bundleIdentifier.isEmpty, !app.version.isEmpty, !app.name.isEmpty else {
            throw RepositoryError.invalid("OTA needs HTTPS and complete application metadata.")
        }
        var assets: [[String: Any]] = [["kind": "software-package", "url": app.downloadURL.absoluteString]]
        if let icon = app.iconURL, icon.scheme == "https" { assets.append(["kind": "display-image", "url": icon.absoluteString, "needs-shine": false]) }
        let manifest: [String: Any] = ["items": [["assets": assets, "metadata": ["bundle-identifier": app.bundleIdentifier, "bundle-version": app.version, "kind": "software", "title": app.name]]]]
        return try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    }
    static func installLink(manifestURL: URL) throws -> URL {
        guard manifestURL.scheme == "https", RepositoryValidator.webURL(manifestURL.absoluteString) != nil else { throw RepositoryError.invalid("A publicly trusted HTTPS manifest URL is required.") }
        var components = URLComponents()
        components.scheme = "itms-services"; components.host = ""
        components.queryItems = [.init(name: "action", value: "download-manifest"), .init(name: "url", value: manifestURL.absoluteString)]
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }
    static func qrCode(_ url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
