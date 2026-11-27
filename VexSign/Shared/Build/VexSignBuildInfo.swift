//
//  VexSignBuildInfo.swift
//  VexSign
//
//  One application-level source for the build metadata written by Xcode.
//  Values come from Info.plist build settings, not source constants, so a
//  version bump never has to be duplicated in Swift. Every value is bounded
//  before it reaches a UI, receipt or diagnostic report.
//

import Foundation

enum VexSignBuildInfo {
    static let unknown = "unknown"

    static var version: String {
        validatedToken(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    static var build: String {
        validatedToken(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// The Xcode configuration's channel: development, prerelease, or release.
    /// It is metadata, not a claim that an artifact is signed or installable.
    static var configuration: String {
        let raw = validatedToken(Bundle.main.object(forInfoDictionaryKey: "VexSignBuildChannel") as? String)
        switch raw {
        case "development", "prerelease", "release": return raw
        default: return unknown
        }
    }

    static var commit: String {
        validatedCommit(Bundle.main.object(forInfoDictionaryKey: "VexSignSourceCommit") as? String)
    }

    /// Stable, secret-free string for receipts, troubleshooting and About.
    static var summary: String {
        "\(version) (\(build)) · \(configuration)"
    }

    static func validatedToken(_ raw: String?) -> String {
        guard let raw, (1...64).contains(raw.count),
              raw.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_+").contains($0)
              }) else { return unknown }
        return raw
    }

    static func validatedCommit(_ raw: String?) -> String {
        guard let raw, (7...40).contains(raw.count),
              raw.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
              }) else { return unknown }
        return raw.lowercased()
    }
}
