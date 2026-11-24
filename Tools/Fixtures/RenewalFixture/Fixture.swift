import CryptoKit
import Foundation
import SwiftUI

/// Test fixture only. No networking or iCloud; a missing marker is never re-created on launch.
@main
struct RenewalFixture: App {
    var body: some Scene { WindowGroup { EvidenceView() } }
}

private struct EvidenceView: View {
    @State private var observation = ""
    @State private var missingMarker = false
    @State private var message = ""

    @State private var command = ""
    @State private var reply = ""

    private var marker: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("renewal-fixture-marker")
    }

    var body: some View {
        Form {
            Section("In-place renewal test") {
                Text("Create the marker before the first observation. If it is missing after reinstall, record a failure; do not create another marker.")
                if missingMarker {
                    Button("Create initial marker") {
                        do {
                            try Data(UUID().uuidString.utf8).write(to: marker, options: .withoutOverwriting)
                            var url = marker
                            var attributes = URLResourceValues()
                            attributes.isExcludedFromBackup = true
                            try url.setResourceValues(attributes)
                            read()
                        } catch { message = error.localizedDescription }
                    }
                }
                Button("Read installed copy", action: read)
                Text(message)
            }
            Section("Manual slot test — marker only") {
                Button("Export fixture backup") { respond(nil) }
                TextField("Paste rehearsal or restore packet", text: $command)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Run fixture request") { respond(command) }
                if !reply.isEmpty { Text(reply).textSelection(.enabled); ShareLink(item: reply) }
            }
            if !observation.isEmpty {
                Section("Observed on this device") {
                    Text(observation).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink(item: observation)
                }
            }
        }.onAppear(perform: read)
    }

    private func respond(_ input: String?) {
        reply = ""
        do {
            guard let bundle = Bundle.main.bundleIdentifier,
                  let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let profile = FixtureSlotPacket.digest(try Data(contentsOf: url))
            func readMarker(_ url: URL) throws -> UUID {
                guard let id = UUID(uuidString: try String(contentsOf: url, encoding: .utf8)) else { throw CocoaError(.fileReadCorruptFile) }
                return id
            }
            guard let input else {
                reply = try FixtureSlotPacket(kind: .backup, bundle: bundle, profile: profile, marker: readMarker(marker), challenge: nil).text()
                return
            }
            let packet = try FixtureSlotPacket.parse(input)
            guard packet.bundle == bundle, packet.profile == profile, packet.challenge != nil else { throw CocoaError(.fileReadCorruptFile) }
            let bytes = Data(packet.marker.uuidString.utf8)
            switch packet.kind {
            case .rehearse:
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: scratch) }
                try bytes.write(to: scratch, options: .withoutOverwriting)
                guard try readMarker(scratch) == packet.marker, try readMarker(marker) == packet.marker else { throw CocoaError(.fileReadCorruptFile) }
                reply = try packet.with(.rehearsed, challenge: packet.challenge).text()
            case .restore:
                if !FileManager.default.fileExists(atPath: marker.path) { try bytes.write(to: marker, options: .withoutOverwriting) }
                guard try readMarker(marker) == packet.marker else { throw CocoaError(.fileReadCorruptFile) }
                reply = try packet.with(.restored, challenge: packet.challenge).text()
                read()
            default: throw CocoaError(.fileReadCorruptFile)
            }
        } catch { message = error.localizedDescription }
    }

    private func read() {
        observation = ""
        missingMarker = !FileManager.default.fileExists(atPath: marker.path)
        guard !missingMarker else { message = "No saved marker."; return }
        guard let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let bundle = Bundle.main.bundleIdentifier else { message = "No embedded profile or bundle identifier."; return }
        do {
            func hash(_ url: URL) throws -> String {
                SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
            let row = ["bundle_id": bundle, "profile_sha256": try hash(profile), "marker_sha256": try hash(marker)]
            observation = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
            message = "Save this observation with the corresponding signed IPA."
        } catch { message = error.localizedDescription }
    }
}
