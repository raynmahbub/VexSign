// MARK: - Injection domain models
//
// Pure, value-only models shared by package inspection, configuration, planning
// and the SwiftUI screens. Nothing here parses an archive, modifies a binary or
// performs signing. Those operations live in dedicated services.

import Foundation
import NimbleExtensions

enum InjectionOutcome: String, Codable, Equatable, Sendable, CaseIterable {
    case compatible
    case incompatible
    case unsupported
    case missingDependency
    case conflictingModification
    case requiresAdditionalValidation
    case invalidPackage

    var displayName: String {
        switch self {
        case .compatible: return .localized("Compatible")
        case .incompatible: return .localized("Incompatible")
        case .unsupported: return .localized("Unsupported")
        case .missingDependency: return .localized("Missing dependency")
        case .conflictingModification: return .localized("Conflicting modification")
        case .requiresAdditionalValidation: return .localized("Requires additional validation")
        case .invalidPackage: return .localized("Invalid package")
        }
    }

    var permitsInjection: Bool { self == .compatible }
}

struct InjectionFinding: Codable, Equatable, Sendable, Identifiable {
    enum Severity: String, Codable, Sendable { case blocking, advisory, informational }
    let code: String
    let severity: Severity
    let detail: String
    var id: String { "\(code)-\(detail)" }
}

/// A parsed Debian relationship such as `Depends: mobilesubstrate (>= 0.9)`.
struct PackageRelation: Codable, Equatable, Sendable {
    let name: String
    let versionConstraint: String?

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum PackageRelationParser {
    /// Splits a Debian control field on commas, but not on commas inside parentheses.
    static func parse(_ field: String?) -> [PackageRelation] {
        guard let field else { return [] }
        var result: [PackageRelation] = []
        var depth = 0
        var current = ""
        for character in field {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character == ",", depth == 0 {
                append(current, to: &result)
                current = ""
            } else {
                current.append(character)
            }
        }
        append(current, to: &result)
        return result
    }

    private static func append(_ raw: String, to result: inout [PackageRelation]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Debian alternatives (`a | b`) are not chosen automatically. Keep the
        // whole expression as one requirement so the planner can ask the user.
        let pieces = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = pieces.first else { return }
        let constraint = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        result.append(PackageRelation(
            name: String(first),
            versionConstraint: constraint?.isEmpty == true ? nil : constraint
        ))
    }
}

/// A filter read from a tweak's metadata plist. Matching is deliberately
/// wildcard-only: no regular expression is evaluated on untrusted input.
struct InjectionFilterRule: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case bundle, executable }
    let kind: Kind
    let pattern: String

    enum ValidationError: LocalizedError, Equatable {
        case empty
        case tooLong
        case invalidWildcard

        var errorDescription: String? {
            switch self {
            case .empty: return String.localized("An empty filter would match nothing and is invalid.")
            case .tooLong: return String.localized("A filter is longer than VexSign accepts.")
            case .invalidWildcard: return String.localized("A filter contains an unsupported wildcard.")
            }
        }

        var description: String { errorDescription ?? "" }
    }

    static func validate(pattern: String) -> ValidationError? {
        guard !pattern.isEmpty else { return .empty }
        guard pattern.utf8.count <= 512 else { return .tooLong }
        var previousWasStar = false
        for character in pattern {
            guard character.isLetter || character.isNumber || ".*-_".contains(character) else {
                return .invalidWildcard
            }
            if character == "*", previousWasStar { return .invalidWildcard }
            previousWasStar = character == "*"
        }
        return nil
    }

    func matches(_ value: String) -> Bool {
        let value = value.lowercased()
        let lower = pattern.lowercased()
        if lower == "*" { return true }
        if lower.hasPrefix("*"), lower.hasSuffix("*") {
            let middle = String(lower.dropFirst().dropLast())
            return !middle.isEmpty && value.contains(middle)
        }
        if lower.hasPrefix("*") { return value.hasSuffix(String(lower.dropFirst())) }
        if lower.hasSuffix("*") { return value.hasPrefix(String(lower.dropLast())) }
        if lower.contains("*") {
            let parts = lower.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            guard let first = parts.first else { return false }
            guard value.hasPrefix(first) else { return false }
            var cursor = value.index(value.startIndex, offsetBy: first.count)
            for part in parts.dropFirst().dropLast() {
                guard part.isEmpty || value.range(of: part, range: cursor..<value.endIndex) != nil else { return false }
                if let range = value.range(of: part, range: cursor..<value.endIndex) {
                    cursor = range.upperBound
                }
            }
            return value.hasSuffix(parts.last ?? "")
        }
        return value == lower
    }
}

/// A complete, structured injection configuration for one tweak.
struct InjectionConfiguration: Codable, Equatable, Sendable {
    let packageID: String
    let version: String
    let enabled: Bool
    let bundleRules: [InjectionFilterRule]
    let executableRules: [InjectionFilterRule]
    let excludedBundleIDs: [String]
    let installPath: String
    let provenance: String

    static func from(
        packageID: String,
        version: String,
        enabled: Bool,
        filter: TweakFilterMetadata?,
        excludedBundleIDs: [String] = [],
        installPath: String,
        provenance: String
    ) -> InjectionConfiguration {
        InjectionConfiguration(
            packageID: packageID,
            version: version,
            enabled: enabled,
            bundleRules: filter?.bundles ?? [],
            executableRules: filter?.executables ?? [],
            excludedBundleIDs: excludedBundleIDs,
            installPath: installPath,
            provenance: provenance
        )
    }

    /// An empty filter means "no target was declared", never "inject everywhere".
    var declaresNoTargets: Bool { bundleRules.isEmpty && executableRules.isEmpty }
}

struct TweakFilterMetadata: Codable, Equatable, Sendable {
    let bundles: [InjectionFilterRule]
    let executables: [InjectionFilterRule]
}

/// One executable or bundle inside an imported app that may receive a load command.
struct InjectionTarget: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let executableName: String?
    let isMain: Bool
}

/// A single auditable step in a modification plan. Contains no secret material.
struct InjectionStep: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case placePayload
        case addLoadCommand
        case redirectHookRuntime
        case reSignNestedCode
        case verifySignature
    }

    let id: String
    let kind: Kind
    let summary: String
    let targetID: String?
}

struct InjectionPlan: Codable, Equatable, Sendable {
    let id: String
    let appIdentifier: String?
    let targets: [InjectionTarget]
    let steps: [InjectionStep]
    let selectedPackageIDs: [String]
    let excludedPackageIDs: [String]
    let findings: [InjectionFinding]
    let outcome: InjectionOutcome
    let requiresSignatureVerification: Bool

    var canApply: Bool { outcome.permitsInjection && !steps.isEmpty }
}

/// An operation report written after a modification attempt. Only public paths,
/// package names and outcomes are recorded.
struct InjectionOperationReport: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case planned, applied, cancelled, failed }
    let id: String
    let planID: String
    let status: Status
    let completedSteps: [String]
    let failedStep: String?
    let findingDetails: [String]
    let finishedAt: Date
}
