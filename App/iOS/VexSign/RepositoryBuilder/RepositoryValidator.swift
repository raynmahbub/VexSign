import Foundation

struct RepositoryIssue: Identifiable, Sendable {
    enum Severity: String, Sendable { case warning, error }
    enum Fix: Sendable { case trimURLs, removeDuplicateScreenshots }
    let id = UUID()
    let appID: UUID?
    let severity: Severity
    let message: String
    let suggestion: String
    var fix: Fix? = nil
}

enum RepositoryValidator {
    static func webURL(_ value: String) -> URL? {
        guard !value.contains(where: { $0.isWhitespace }),
              let url = URL(string: value), let host = url.host, !host.isEmpty,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func validate(_ doc: RepositoryDocument) -> [RepositoryIssue] {
        var issues: [RepositoryIssue] = []
        func add(_ id: UUID?, _ severity: RepositoryIssue.Severity, _ message: String, _ suggestion: String, _ fix: RepositoryIssue.Fix? = nil) {
            issues.append(.init(appID: id, severity: severity, message: message, suggestion: suggestion, fix: fix))
        }
        if doc.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || doc.identifier.isEmpty {
            add(nil, .error, "Repository name and identifier are required.", "Enter a stable identifier and a display name.")
        }
        if !doc.iconURL.isEmpty, webURL(doc.iconURL) == nil { add(nil, .error, "Invalid repository icon URL.", "Use an absolute HTTPS URL.") }
        var ids = Set<String>()
        for app in doc.apps {
            if app.name.isEmpty || app.version.isEmpty || app.bundleIdentifier.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) == nil {
                add(app.id, .error, "\(app.name): missing name/version or invalid bundle ID.", "Use a reverse-DNS identifier.")
            }
            if !ids.insert(app.bundleIdentifier.lowercased()).inserted { add(app.id, .error, "Duplicate bundle ID: \(app.bundleIdentifier)", "Merge releases or assign a unique bundle ID.") }
            if app.iconURL.isEmpty { add(app.id, .warning, "\(app.name): missing icon.", "Provide a publicly accessible iconURL.") }
            if app.size <= 0 { add(app.id, .warning, "\(app.name): unknown download size.", "Set the IPA size in bytes.") }
            let date = ISO8601DateFormatter()
            date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
            if ISO8601DateFormatter().date(from: app.versionDate) == nil && date.date(from: app.versionDate) == nil && day.date(from: app.versionDate) == nil {
                add(app.id, .error, "\(app.name): invalid version date.", "Use ISO 8601 or YYYY-MM-DD.")
            }
            if !app.tintColor.isEmpty, app.tintColor.range(of: #"^#?[0-9A-Fa-f]{6}$"#, options: .regularExpression) == nil {
                add(app.id, .warning, "\(app.name): invalid tint color.", "Use six hexadecimal digits.")
            }
            for value in [app.downloadURL] + (app.iconURL.isEmpty ? [] : [app.iconURL]) + app.screenshotURLs {
                guard let url = webURL(value) else {
                    let canTrim = webURL(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
                    add(app.id, .error, "\(app.name): invalid URL: \(value)", "Use an absolute HTTPS URL.", canTrim ? .trimURLs : nil)
                    continue
                }
                if url.scheme == "http" { add(app.id, .warning, "\(app.name): insecure HTTP URL.", "Confirm HTTPS support before changing this URL.") }
            }
            if Set(app.screenshotURLs).count != app.screenshotURLs.count {
                add(app.id, .warning, "\(app.name): repeated screenshots.", "Remove duplicate screenshot URLs.", .removeDuplicateScreenshots)
            }
        }
        return issues
    }

    /// Explicit, user-initiated probes only. HEAD avoids downloading large IPA files.
    /// A failed HEAD is 'unverified', not proof of revocation or a broken IPA.
    static func checkDownloads(_ doc: RepositoryDocument) async -> [RepositoryIssue] {
        var issues: [RepositoryIssue] = []
        for start in stride(from: 0, to: doc.apps.count, by: 4) {
            if Task.isCancelled { break }
            let batch = doc.apps[start..<min(start + 4, doc.apps.count)]
            await withTaskGroup(of: RepositoryIssue?.self) { group in
                for app in batch {
                    group.addTask {
                        guard let url = webURL(app.downloadURL) else { return nil }
                        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = "HEAD"
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
    static func applySafeFixes(to doc: inout RepositoryDocument) {
        for index in doc.apps.indices {
            doc.apps[index].downloadURL = doc.apps[index].downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
            doc.apps[index].iconURL = doc.apps[index].iconURL.trimmingCharacters(in: .whitespacesAndNewlines)
            var seen = Set<String>()
            doc.apps[index].screenshotURLs = doc.apps[index].screenshotURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { seen.insert($0).inserted }
        }
    }
}
