import Foundation
import UniformTypeIdentifiers
import NimbleExtensions

/// Coordinates Home tab import, drop, quick-sign, and URL download actions cleanly outside `HomeView`.
@MainActor
final class HomeActionCoordinator {
    private let securityPolicy: SecurityPolicyValidating
    private let platform: PlatformSystemAdapting
    private let enqueuePackageHandler: (URL, Bool) -> Void
    private let startURLDownloadHandler: (URL) -> Bool
    private let revealTabHandler: (TabEnum) -> Void

    init(
        securityPolicy: SecurityPolicyValidating,
        platform: PlatformSystemAdapting,
        enqueuePackageHandler: @escaping (URL, Bool) -> Void,
        startURLDownloadHandler: @escaping (URL) -> Bool,
        revealTabHandler: @escaping (TabEnum) -> Void
    ) {
        self.securityPolicy = securityPolicy
        self.platform = platform
        self.enqueuePackageHandler = enqueuePackageHandler
        self.startURLDownloadHandler = startURLDownloadHandler
        self.revealTabHandler = revealTabHandler
    }

    func openTab(_ tab: TabEnum) {
        revealTabHandler(tab)
    }

    func enqueuePackage(_ url: URL, quickSign: Bool = false) {
        guard let stagedURL = stagePackage(url) else { return }
        enqueuePackageHandler(stagedURL, quickSign)
    }

    func stagePackage(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let fileManager = FileManager.default
        let directory = fileManager.downloadStaging
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = FileManagerActions.uniqueURL(for: url.lastPathComponent, in: directory)
            try fileManager.copyItem(at: url, to: target)
            return target
        } catch {
            platform.notifyError(error.localizedDescription, sticky: false)
            return nil
        }
    }

    func startURLDownload(rawURL: String) -> Bool {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            platform.notifyError(.localized("Enter a valid HTTP or HTTPS app URL."), sticky: true)
            return false
        }

        do {
            try securityPolicy.validatePackageDownloadURL(url)
        } catch {
            platform.notifyError(ErrorBoundary.userMessage(for: error), sticky: true)
            return false
        }

        guard startURLDownloadHandler(url) else { return false }
        platform.notifyInfo(.localized("Check Downloads for status."), systemImage: "arrow.down.circle")
        return true
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            let identifier = provider.registeredTypeIdentifiers.first { id in
                UTType(id)?.conforms(to: .fileURL) == true
            } ?? UTType.fileURL.identifier

            provider.loadItem(forTypeIdentifier: identifier, options: nil) { [weak self] item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let itemURL = item as? NSURL {
                    url = itemURL as URL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let path = item as? String {
                    url = URL(fileURLWithPath: path)
                } else {
                    url = nil
                }

                guard let url else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.securityPolicy.isAllowedPackageExtension(url.pathExtension) else {
                        self.platform.notifyError(.localized("Please drop an IPA or TIPA file."), sticky: true)
                        return
                    }
                    self.enqueuePackage(url)
                }
            }
        }
        return true
    }
}
