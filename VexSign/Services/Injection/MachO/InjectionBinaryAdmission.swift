// MARK: - Pre/post checks around the native load-command injector
//
// VexSign deliberately keeps one mutation mechanism for user apps: the pinned
// native signing engine. This module does not patch production binaries. It
// proves before the engine runs that the proposed load command has a safe,
// in-place layout in the verified thin/fat arm64 file, and reads the result
// back afterwards. Unsupported layouts are refused before anything is placed.

import Foundation
import NimbleExtensions

enum InjectionBinaryAdmissionError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupportedLayout(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return String.localized("The executable %@ could not be read for injection safety checks.", arguments: name)
        case .unsupportedLayout(let detail):
            return String.localized("VexSign cannot safely modify this executable layout: %@", arguments: detail)
        }
    }
}

enum InjectionBinaryAdmission {
    private static let maximumExecutableBytes: Int64 = 512 * 1024 * 1024

    /// Refuse to start a structured modification if the host executable cannot
    /// accept a load command in place. An already-present path is not a layout
    /// error: the native engine reports it separately.
    static func validate(executableAt url: URL, proposedLoadPath: String) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 // try? ok: unreadable files are reported through the typed error below
        guard size > 0, size <= maximumExecutableBytes else {
            throw InjectionBinaryAdmissionError.unreadable(url.lastPathComponent)
        }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw InjectionBinaryAdmissionError.unreadable(url.lastPathComponent) }

        do {
            _ = try MachOLoadCommandInjector.plan(in: data, loadPath: proposedLoadPath)
        } catch MachOLoadCommandError.duplicateLoadPath {
            return
        } catch {
            throw InjectionBinaryAdmissionError.unsupportedLayout(error.localizedDescription)
        }
    }

    /// After the native engine reports success, confirm the requested path is
    /// actually present in the re-read binary. This is structural evidence only
    /// and never a runtime-compatibility claim.
    static func verify(executableAt url: URL, expectedLoadPath: String) throws {
        guard MachOReader.dylibs(forExecutableAt: url).contains(expectedLoadPath) else {
            throw InjectionBinaryAdmissionError.unsupportedLayout(
                .localized("the expected load command was not present after signing")
            )
        }
    }
}
