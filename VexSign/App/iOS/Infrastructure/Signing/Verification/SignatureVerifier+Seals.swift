import Foundation
import CryptoKit
import Zsign

extension SignatureVerifier {
    /// Run-owned public evidence, never private-key material. Each profile-bound
    /// component has its own expectation; libraries inherit the nearest owner's
    /// signer, not necessarily the main application's signer.
    struct AssetExpectation {
        let bundleIdentifier: String
        let certificateFingerprint: String
        let teamIdentifier: String
        let profileDigest: String
        let entitlements: [String: Any]
        var platform: String = "iOS"
        var deviceUDID: String? = nil
    }

    struct SealFailure: LocalizedError {
        let code: Issue.Code
        let errorDescription: String?
        init(_ detail: String) { self.init(.signatureInvalid, detail) }
        init(_ code: Issue.Code, _ detail: String) {
            self.code = code; errorDescription = detail
        }
    }

    static func freshSealIssues(in root: URL, assets: [String: AssetExpectation]) -> [Issue] {
        var issues: [Issue] = []
        let plan = SigningPlan.make(appBundle: root)
        for issue in plan.validationIssues().filter({ $0.severity == .blocking }) {
            issues.append(.init(code: .manifestInvalid, severity: .failure, detail: issue.detail))
        }
        let paths = Set(["."] + plan.profileBoundComponents.map(\.path))
        guard paths == Set(assets.keys) else {
            issues.append(.init(code: .expectedAssetsMissing, severity: .failure,
                detail: "The produced component manifest differs from the authenticated signing plan. Nothing has been registered as successfully signed."))
            return issues
        }
        var hashCache: [URL: ResourceHashes] = [:]
        let components: [(String, SigningPlan.Component?)] = [(".", nil)] + plan.components.filter { !$0.isResourceOnly }.map { ($0.path, $0) }
        let owners = assets.keys.sorted { $0.count > $1.count }
        for (path, component) in components {
            do {
                try Task.checkCancellation()
                guard let owner = owners.first(where: { $0 == "." || path == $0 || path.hasPrefix($0 + "/") }),
                      let asset = assets[owner] else { throw SealFailure(.expectedAssetsMissing, "No authenticated signer is assigned to this component.") }
                let url = path == "." ? root : root.appendingPathComponent(path)
                let isDylib = component?.kind == .dylib
                let isProfileBound = path == "." || component?.kind.requiresProfile == true
                let executable = isDylib ? url : SigningInputValidation.executable(in: url)
                guard let executable else { throw SealFailure(.executableMissing, "The component has no readable executable.") }
                let info: Data?
                if isDylib { info = nil }
                else { info = try CertificateInputReader.read(url.appendingPathComponent("Info.plist")) }
                let resources: Data?
                if isDylib { resources = nil }
                else { resources = try verifyResources(in: url, executable: executable, cache: &hashCache) }
                let expectedEntitlements = isProfileBound ? asset.entitlements : [:]
                let identifier = isDylib ? nil : (isProfileBound ? asset.bundleIdentifier : component?.identifier)
                let signer = try verifyExecutable(at: executable, identifier: identifier, team: asset.teamIdentifier,
                    certificateFingerprint: asset.certificateFingerprint, entitlements: expectedEntitlements,
                    info: info, resources: resources, expectsApplication: isProfileBound)
                if isProfileBound {
                    guard readInfo(at: url)?["CFBundleIdentifier"] as? String == asset.bundleIdentifier else {
                        throw SealFailure(.bundleIdentifierMismatch, "The produced Bundle Identifier differs from the reviewed component identifier.")
                    }
                    let profileData = try CertificateInputReader.read(url.appendingPathComponent("embedded.mobileprovision"))
                    guard SigningIdentity.fingerprint(of: profileData) == asset.profileDigest else {
                        throw SealFailure(.profileChanged, "The embedded profile differs from the exact authenticated profile selected for this component.")
                    }
                    let profile = try ProvisioningProfileParser.parse(profileData)
                    let candidate = SigningProfileCandidate(id: path,
                        identity: .init(reference: path, fingerprint: signer.fingerprint,
                            teamIdentifier: signer.teamIdentifier, displayName: signer.commonName,
                            notBefore: signer.notBefore, notAfter: signer.notAfter, keyAvailability: .accessible),
                        profile: profile, isAuthenticated: true,
                        authorizedCertificateFingerprints: Set((profile.DeveloperCertificates ?? []).map { SigningIdentity.fingerprint(of: $0) }))
                    let validation = ProfileCompatibilityValidator.evaluate(candidate,
                        for: .init(relativePath: path, bundleIdentifier: asset.bundleIdentifier,
                            platform: asset.platform, requiredEntitlements: expectedEntitlements), deviceUDID: asset.deviceUDID)
                    guard validation.status == .valid else {
                        throw SealFailure(.entitlementNotGranted, validation.issues.map(\.detail).joined(separator: " "))
                    }
                }
            } catch {
                let code = (error as? SealFailure)?.code ?? .signatureInvalid
                issues.append(.init(code: code, severity: .failure,
                    detail: path + ": " + error.localizedDescription, subject: path))
            }
        }
        return issues
    }

    /// Independent byte/hash/CMS verification for every thin or fat image. The
    /// expected certificate was authorized by an authenticated profile BEFORE
    /// signing; a CMS's embedded certificate list is not itself a trust anchor.
    static func verifyExecutable(at url: URL, identifier: String?, team: String,
                                 certificateFingerprint: String, entitlements: [String: Any],
                                 info: Data?, resources: Data?, expectsApplication: Bool,
                                 now: Date = Date()) throws -> SigningIdentity {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 2 * 1024 * 1024 * 1024 else { throw SealFailure("The executable exceeds the supported inspection size.") }
        let actual = try MachOEntitlements.requiredEntitlements(in: data)
        guard MachOEntitlements.equivalent(actual, entitlements) else {
            throw SealFailure(.entitlementNotGranted, "The sealed entitlements differ from the exact authorized component plan.")
        }
        let images = try MachOEntitlements.images(in: data)
        var signer: SigningIdentity?
        for image in images {
            try Task.checkCancellation()
            guard let signature = image.signatureRange, signature.upperBound == image.range.upperBound,
                  let primary = image.blobs[0], let cms = image.blobs[0x10000],
                  MachOReader.u32(cms, at: 0, bigEndian: true) == 0xfade0b01,
                  image.blobs[2] != nil, image.blobs[5] != nil,
                  Set(image.blobs.keys).isSubset(of: [0, 2, 5, 7, 0x1000, 0x10000]) else {
                throw SealFailure("A component image is unsigned, malformed, or has an unsupported signature layout.")
            }
            let base = image.range.lowerBound
            let magic = MachOReader.u32(data, at: base, bigEndian: false)
            let big = magic == 0xcffaedfe || magic == 0xcefaedfe
            guard let fileType = MachOReader.u32(data, at: base + 12, bigEndian: big),
                  (expectsApplication ? fileType == 2 : [UInt32(6), 8].contains(fileType)),
                  !expectsApplication || image.blobs[7] != nil else { throw SealFailure("The component's executable type or entitlement slots do not match its signing role.") }
            let embedded = try embeddedInfo(in: data, image: image.range)
            let metadata = info ?? embedded.plist
            let embeddedIdentifier = try embedded.plist.flatMap {
                (try PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any])?["CFBundleIdentifier"] as? String
            }
            let expectedIdentifier = identifier ?? embeddedIdentifier ?? url.lastPathComponent
            var special = image.blobs.filter { [UInt32(2), 5, 7].contains($0.key) }
            if let metadata { special[1] = metadata }
            if let resources { special[3] = resources }
            let prefix = image.range.lowerBound..<signature.lowerBound
            let debug = (entitlements["get-task-allow"] as? NSNumber)?.boolValue == true
            let flags: UInt64 = fileType == 2 ? (debug ? 0x11 : 1) : 0
            let primaryType = try verifyDirectory(primary, executable: data, prefix: prefix,
                identifier: expectedIdentifier, team: team, special: special,
                textLimit: embedded.textLimit, executionFlags: flags)
            let alternate = image.blobs[0x1000]
            if let alternate {
                guard primaryType == 1,
                      try verifyDirectory(alternate, executable: data, prefix: prefix,
                        identifier: expectedIdentifier, team: team, special: special,
                        textLimit: embedded.textLimit, executionFlags: flags) == 2 else {
                    throw SealFailure("The alternate CodeDirectory is inconsistent with the primary directory.")
                }
            } else if primaryType != 2 { throw SealFailure("A SHA256 CodeDirectory is required.") }
            guard let certificate = VexVerifyCodeSignatureCMS(Data(cms.dropFirst(8)), primary, alternate),
                  let identity = SigningIdentity(certificate), identity.fingerprint == certificateFingerprint,
                  identity.teamIdentifier == team, let from = identity.notBefore, let until = identity.notAfter,
                  from <= now, until > now else { throw SealFailure(.signerMismatch, "The cryptographic signer is missing, invalid, expired, or differs from the authorized identity.") }
            if let signer, signer.fingerprint != identity.fingerprint { throw SealFailure(.signerMismatch, "The executable slices carry different signing identities.") }
            signer = identity
        }
        guard let signer else { throw SealFailure("No signed executable image was found.") }
        return signer
    }

    /// Deliberately verifies the native engine's emitted v0x20400 format, not a
    /// permissive generic CodeDirectory parser. Unsupported layouts fail closed.
    @discardableResult
    static func verifyDirectory(_ directory: Data, executable: Data, prefix: Range<Int>,
                                identifier: String, team: String, special: [UInt32: Data],
                                textLimit: UInt64, executionFlags: UInt64) throws -> UInt8 {
        guard (88...16 * 1024 * 1024).contains(directory.count), prefix.lowerBound >= 0,
              prefix.upperBound <= executable.count, !prefix.isEmpty else { throw SealFailure("Invalid CodeDirectory bounds.") }
        let bytes = [UInt8](directory)
        func word(_ offset: Int) -> Int { Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) }
        func wide(_ offset: Int) -> UInt64 { UInt64(word(offset)) << 32 | UInt64(word(offset + 4)) }
        let hashType = bytes[37], hashSize = Int(bytes[36]), specialCount = word(24)
        guard word(0) == 0xfade0c02, word(4) == bytes.count, word(8) == 0x20400, word(12) == 0,
              word(20) == 88, word(32) == prefix.count, [UInt8(1), 2].contains(hashType),
              hashSize == (hashType == 1 ? 20 : 32), (0...7).contains(specialCount),
              bytes[38] == 0, bytes[39] == 12, word(40) == 0, word(44) == 0, word(52) == 0, wide(56) == 0,
              wide(64) == 0, wide(72) == textLimit, wide(80) == executionFlags else { throw SealFailure("The CodeDirectory header is unsupported or inconsistent.") }
        let id = Data(identifier.utf8) + Data([0]), teamBytes = Data(team.utf8) + Data([0])
        let stringsEnd = 88 + id.count + teamBytes.count, hashOffset = stringsEnd + specialCount * hashSize
        let pages = (prefix.count + 4095) / 4096
        guard word(48) == 88 + id.count, word(16) == hashOffset, word(28) == pages,
              bytes.count == hashOffset + pages * hashSize,
              Data(bytes[88..<(88 + id.count)]) == id,
              Data(bytes[(88 + id.count)..<stringsEnd]) == teamBytes,
              special.keys.allSatisfy({ $0 > 0 && $0 <= UInt32(specialCount) }) else { throw SealFailure("The CodeDirectory strings, slots or page count are inconsistent.") }
        func hash(_ data: Data) -> Data { hashType == 1 ? Data(Insecure.SHA1.hash(data: data)) : Data(SHA256.hash(data: data)) }
        if specialCount > 0 {
            for slot in 1...specialCount {
                let expected = special[UInt32(slot)].map(hash) ?? Data(repeating: 0, count: hashSize)
                let start = hashOffset - slot * hashSize
                guard Data(bytes[start..<(start + hashSize)]) == expected else { throw SealFailure("A sealed Info.plist, resource envelope, requirement or entitlement slot was changed.") }
            }
        }
        for page in 0..<pages {
            try Task.checkCancellation()
            let start = prefix.lowerBound + page * 4096
            let expected = hash(executable.subdata(in: start..<min(start + 4096, prefix.upperBound)))
            let offset = hashOffset + page * hashSize
            guard Data(bytes[offset..<(offset + hashSize)]) == expected else { throw SealFailure("A signed executable page does not match its cryptographic seal.") }
        }
        return hashType
    }

    /// Segment/section bounds have already been checked by ExecutablePreflight.
    private static func embeddedInfo(in data: Data, image: Range<Int>) throws -> (plist: Data?, textLimit: UInt64) {
        let base = image.lowerBound
        let magic = MachOReader.u32(data, at: base, bigEndian: false)
        let big = magic == 0xcffaedfe || magic == 0xcefaedfe, is64 = magic == 0xfeedfacf || magic == 0xcffaedfe
        func word(_ offset: Int) -> UInt32 { MachOReader.u32(data, at: base + offset, bigEndian: big) ?? 0 }
        func wide(_ offset: Int) -> UInt64 { big ? UInt64(word(offset)) << 32 | UInt64(word(offset + 4)) : UInt64(word(offset + 4)) << 32 | UInt64(word(offset)) }
        func name(_ offset: Int) -> String { String(decoding: data[(base + offset)..<(base + offset + 16)].prefix(while: { $0 != 0 }), as: UTF8.self) }
        var offset = is64 ? 32 : 28, info: Data?, textLimit: UInt64 = 0
        for _ in 0..<word(16) {
            let command = word(offset)
            if command == 1 || command == 0x19, name(offset + 8) == "__TEXT" {
                let segment64 = command == 0x19
                textLimit = segment64 ? wide(offset + 32) : UInt64(word(offset + 28))
                let count = word(offset + (segment64 ? 64 : 48))
                for index in 0..<Int(count) {
                    let section = offset + (segment64 ? 72 : 56) + index * (segment64 ? 80 : 68)
                    if name(section) == "__info_plist" {
                        let start = Int(word(section + (segment64 ? 48 : 40)))
                        let length = segment64 ? wide(section + 40) : UInt64(word(section + 36))
                        guard info == nil, length <= 1024 * 1024, UInt64(start) + length <= UInt64(image.count) else { throw SealFailure("The embedded Info.plist is ambiguous or too large.") }
                        info = data.subdata(in: (base + start)..<(base + start + Int(length)))
                    }
                }
            }
            offset += Int(word(offset + 4))
        }
        return (info, textLimit)
    }

    struct ResourceHashes { let sha1: Data; let sha256: Data }

    /// Checks every generated resource entry and every actual regular file. No
    /// arbitrary rule or optional flag can hide an unsealed file in a fresh run.
    static func verifyResources(in bundle: URL, executable: URL, cache: inout [URL: ResourceHashes]) throws -> Data {
        let seal = bundle.appendingPathComponent("_CodeSignature/CodeResources")
        let values = try seal.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= 16 * 1024 * 1024 else { throw SealFailure(.missingCodeResources, "Missing or unreadable resource envelope.") }
        let data = try Data(contentsOf: seal)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let files = dictionary["files"] as? [String: Any], let files2 = dictionary["files2"] as? [String: [String: Any]],
              files.count <= 50_000, files2.count <= 50_000 else { throw SealFailure(.resourceSealInvalid, "Malformed resource envelope.") }
        var walkError: Error?, seen1 = Set<String>(), seen2 = Set<String>(), count = 0
        guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in walkError = error; return false }) else { throw SealFailure(.resourceSealInvalid, "Resource enumeration is unavailable.") }
        for case let url as URL in walker {
            try Task.checkCancellation()
            count += 1
            guard count <= 50_000 else { throw SealFailure(.resourceSealInvalid, "Resource enumeration is incomplete.") }
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw SealFailure(.resourceSealInvalid, "Linked resource paths are unsupported.") }
            guard properties.isRegularFile == true, url != seal, url != executable else { continue }
            let path = String(url.path.dropFirst(bundle.path.count + 1))
            if path.hasSuffix(".lproj/locversion.plist") { continue }
            let hashes: ResourceHashes
            if let cached = cache[url] { hashes = cached }
            else {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() } // try? ok: read/hash failures throw; close is best-effort cleanup.
                var sha1 = Insecure.SHA1(), sha256 = SHA256()
                while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
                    try Task.checkCancellation(); sha1.update(data: block); sha256.update(data: block)
                }
                hashes = .init(sha1: Data(sha1.finalize()), sha256: Data(sha256.finalize()))
                cache[url] = hashes
            }
            let entry1 = files[path] as? Data ?? (files[path] as? [String: Any])?["hash"] as? Data
            guard entry1 == hashes.sha1 else { throw SealFailure(.resourceSealInvalid, "A resource file differs from its SHA1 seal: " + path) }
            seen1.insert(path)
            if !path.hasSuffix(".DS_Store"), path != "Info.plist", path != "PkgInfo" {
                guard files2[path]?["hash"] as? Data == hashes.sha1, files2[path]?["hash2"] as? Data == hashes.sha256 else {
                    throw SealFailure(.resourceSealInvalid, "A resource file differs from its SHA256 seal: " + path)
                }
                seen2.insert(path)
            }
        }
        if let walkError { throw walkError }
        guard seen1 == Set(files.keys), seen2 == Set(files2.keys) else { throw SealFailure(.resourceSealInvalid, "The resource envelope omits files or names missing files.") }
        return data
    }
}
