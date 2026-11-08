import Foundation
import CryptoKit
import UIKit

/// Local thumbnails for persisted task receipts, independent of repository URLs.
/// Owned by the task center; pruning uses retained task IDs, not remote metadata.
@MainActor
final class TaskIconArchive {
    private let root: URL
    private let images = NSCache<NSString, UIImage>()

    init(root: URL? = nil) {
        self.root = root ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("TaskIcons", isDirectory: true)
        images.countLimit = 200
    }

    private func name(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    func image(for id: String) -> UIImage? {
        if let image = images.object(forKey: id as NSString) { return image }
        let url = root.appendingPathComponent(name(id))
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: id as NSString)
        return image
    }

    func store(_ image: UIImage, for id: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        guard let data = thumbnail.pngData() else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name(id)), options: .atomic)
        images.setObject(thumbnail, forKey: id as NSString)
    }

    func prune(keeping ids: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let keep = Set(ids.map(name))
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !keep.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
        images.removeAllObjects()
    }
}
