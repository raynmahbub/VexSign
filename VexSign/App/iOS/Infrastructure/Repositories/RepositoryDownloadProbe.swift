import Foundation

extension RepositoryValidator {
    /// Explicit, user-initiated probes only. HEAD avoids downloading large IPA files.
    /// A failed HEAD is 'unverified', not proof of revocation or a broken IPA.
    static func checkDownloads(_ doc: RepositoryDocument) async -> [RepositoryIssue] {
        var issues: [RepositoryIssue] = []
        let width = RepositoryNetworkPolicy.maxConcurrentProbes
        for start in stride(from: 0, to: doc.apps.count, by: width) {
            if Task.isCancelled { break }
            let batch = doc.apps[start..<min(start + width, doc.apps.count)]
            await withTaskGroup(of: RepositoryIssue?.self) { group in
                for app in batch {
                    group.addTask {
                        guard let url = webURL(app.downloadURL) else { return nil }
                        var request = URLRequest(url: url, timeoutInterval: RepositoryNetworkPolicy.probeTimeout); request.httpMethod = "HEAD"
                        do {
                            let (_, response) = try await URLSession.shared.data(for: request)
                            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return nil }
                            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                            return .init(appID: app.id, severity: status == 404 || status == 410 ? .error : .warning,
                                         message: "\(app.name): download probe returned HTTP \(status).", suggestion: "Verify the download in a browser; some hosts reject HEAD requests.")
                        } catch {
                            return .init(appID: app.id, severity: .warning, message: "\(app.name): download could not be verified.", suggestion: error.localizedDescription)
                        }
                    }
                }
                for await issue in group { if let issue { issues.append(issue) } }
            }
        }
        return issues
    }
}
