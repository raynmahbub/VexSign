import Foundation

/// Bounded signature/entitlement extraction shared with the existing verifier.
/// Absent entitlements and unreadable entitlements are different answers.
enum MachOEntitlements {
    struct Image {
        let range: Range<Int>
        let signatureRange: Range<Int>?
        let blobs: [UInt32: Data]
    }
    enum InspectionFailure: LocalizedError {
        case unreadable, malformed, unsupportedDER, differentSlices
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The component executable could not be read."
            case .malformed: return "The Mach-O signature or entitlements are malformed; required capabilities cannot be established."
            case .unsupportedDER: return "This entitlement DER uses an unsupported encoding or value type. Its capabilities have not been ignored or silently replaced by the XML view."
            case .differentSlices: return "The executable slices request different entitlements. An unambiguous component capability set is required."
            }
        }
    }

    static func keychainAccessGroups(forExecutableAt url: URL) -> [String] {
        read(forExecutableAt: url)?["keychain-access-groups"] as? [String] ?? []
    }

    /// Management/display compatibility API. Admission uses the throwing API below.
    static func read(forExecutableAt url: URL) -> [String: Any]? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard try images(in: data).contains(where: { $0.blobs[5] != nil }) else { return nil }
            return try requiredEntitlements(in: data)
        } catch { return nil }
    }

    static func requiredEntitlements(forExecutableAt url: URL) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw InspectionFailure.unreadable }
        return try requiredEntitlements(in: data)
    }

    static func requiredEntitlements(in data: Data) throws -> [String: Any] {
        var required: [String: Any]?
        for image in try images(in: data) {
            try Task.checkCancellation()
            let values: [String: Any]
            if let blob = image.blobs[5] {
                guard blob.count > 8, blob.count <= 1024 * 1024,
                      let dictionary = try PropertyListSerialization.propertyList(from: Data(blob.dropFirst(8)), options: [], format: nil) as? [String: Any],
                      ProfileEntitlementAuthorization.isBoundedPropertyList(dictionary) else { throw InspectionFailure.malformed }
                if let der = image.blobs[7] {
                    guard equivalent(dictionary, try decodeDEREntitlements(Data(der.dropFirst(8)))) else {
                        throw InspectionFailure.malformed
                    }
                }
                values = dictionary
            } else if let der = image.blobs[7] {
                values = try decodeDEREntitlements(Data(der.dropFirst(8)))
            } else {
                values = [:] // A structurally readable unsigned/no-entitlement image, not a parse failure.
            }
            if let previous = required {
                guard equivalent(previous, values) else { throw InspectionFailure.differentSlices }
            } else { required = values }
        }
        guard let required else { throw InspectionFailure.malformed }
        return required
    }

    static func equivalent(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        func same(_ lhs: Any, _ rhs: Any, depth: Int) -> Bool {
            guard depth <= 32 else { return false }
            if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
                return Set(left.keys) == Set(right.keys) && left.allSatisfy { key, value in
                    right[key].map { same(value, $0, depth: depth + 1) } ?? false
                }
            }
            if let left = lhs as? [Any], let right = rhs as? [Any] {
                return left.count == right.count && zip(left, right).allSatisfy { same($0.0, $0.1, depth: depth + 1) }
            }
            if let left = lhs as? String, let right = rhs as? String { return left == right }
            if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
                let boolean = type(of: NSNumber(value: true))
                return (type(of: left) == boolean) == (type(of: right) == boolean) && left == right
            }
            if let left = lhs as? Data, let right = rhs as? Data { return left == right }
            if let left = lhs as? Date, let right = rhs as? Date { return left == right }
            return false
        }
        return same(lhs, rhs, depth: 0)
    }

    /// Canonical plist-DER subset emitted by the existing native signer. Newer
    /// opaque CoreEntitlements encodings and unsupported scalar types remain
    /// explicitly unsupported, rather than trusting XML that could disagree.
    static func decodeDEREntitlements(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 1024 * 1024 else { throw InspectionFailure.malformed }
        let bytes = [UInt8](data)
        guard let root = DER.element(bytes, at: 0), root.end == bytes.count else { throw InspectionFailure.malformed }
        guard root.tag == 0x31 else { throw InspectionFailure.unsupportedDER }
        var budget = 4096
        func children(_ node: DER.Element) throws -> [DER.Element] {
            var result: [DER.Element] = [], offset = node.content
            while offset < node.end {
                budget -= 1
                guard budget >= 0, let child = DER.element(bytes, at: offset, limit: node.end) else { throw InspectionFailure.malformed }
                result.append(child); offset = child.end
            }
            return result
        }
        func value(_ node: DER.Element, depth: Int) throws -> Any {
            guard depth <= 32 else { throw InspectionFailure.malformed }
            switch node.tag {
            case 0x01:
                guard node.contentLength == 1, [UInt8(0), 0xff].contains(bytes[node.content]) else { throw InspectionFailure.malformed }
                return NSNumber(value: bytes[node.content] != 0)
            case 0x02:
                let raw = DER.content(of: node, in: bytes)
                guard (1...8).contains(raw.count), raw.count == 1 || !((raw[0] == 0 && raw[1] & 0x80 == 0) || (raw[0] == 0xff && raw[1] & 0x80 != 0)) else { throw InspectionFailure.malformed }
                var number: UInt64 = raw[0] & 0x80 != 0 ? UInt64.max : 0
                for byte in raw { number = (number << 8) | UInt64(byte) }
                return NSNumber(value: Int64(bitPattern: number))
            case 0x0c:
                guard node.contentLength <= 8192, let text = String(bytes: bytes[node.content..<node.end], encoding: .utf8) else { throw InspectionFailure.malformed }
                return text
            case 0x30:
                return try children(node).map { try value($0, depth: depth + 1) }
            case 0x31:
                var dictionary: [String: Any] = [:]
                var previous: [UInt8]?
                for pair in try children(node) {
                    guard pair.tag == 0x30 else { throw InspectionFailure.malformed }
                    let encoded = DER.raw(pair, in: bytes)
                    if let previous, !previous.lexicographicallyPrecedes(encoded) { throw InspectionFailure.malformed }
                    previous = encoded
                    let fields = try children(pair)
                    guard fields.count == 2, fields[0].tag == 0x0c,
                          let key = try value(fields[0], depth: depth + 1) as? String,
                          !key.isEmpty, dictionary[key] == nil else { throw InspectionFailure.malformed }
                    dictionary[key] = try value(fields[1], depth: depth + 1)
                }
                return dictionary
            default: throw InspectionFailure.unsupportedDER
            }
        }
        guard let dictionary = try value(root, depth: 0) as? [String: Any],
              ProfileEntitlementAuthorization.isBoundedPropertyList(dictionary) else { throw InspectionFailure.malformed }
        return dictionary
    }

    static func hasCodeSignature(forExecutableAt url: URL) -> Bool {
        do {
            let images = try images(in: Data(contentsOf: url, options: .mappedIfSafe))
            return !images.isEmpty && images.allSatisfy { $0.signatureRange != nil }
        } catch { return false }
    }

    static func codeSignatureOffset(forExecutableAt url: URL) -> Int? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let values = try images(in: data)
            guard let evidence = ExecutablePreflight.inspectImages(data) else { return nil }
            let index = evidence.firstIndex(where: { $0.evidence.isArm64 }) ?? 0
            return values[index].signatureRange?.lowerBound
        } catch { return nil }
    }

    static func images(in data: Data) throws -> [Image] {
        guard let images = ExecutablePreflight.inspectImages(data), !images.isEmpty else { throw InspectionFailure.malformed }
        return try images.map { image in
            let base = image.range.lowerBound
            let magic = MachOReader.u32(data, at: base, bigEndian: false)
            let big = magic == 0xcffaedfe || magic == 0xcefaedfe
            let header = magic == 0xfeedfacf || magic == 0xcffaedfe ? 32 : 28
            func word(_ at: Int) throws -> UInt32 {
                guard at >= base, at <= image.range.upperBound - 4,
                      let value = MachOReader.u32(data, at: at, bigEndian: big) else { throw InspectionFailure.malformed }
                return value
            }
            let count = try word(base + 16)
            let commandsEnd = base + header + Int(try word(base + 20))
            var command = base + header
            var signature: Range<Int>?
            for _ in 0..<count {
                let type = try word(command), size = Int(try word(command + 4))
                if type == 0x1d {
                    guard size == 16, signature == nil else { throw InspectionFailure.malformed }
                    let offset = base + Int(try word(command + 8)), length = Int(try word(command + 12))
                    guard offset >= commandsEnd, length >= 12, length <= 16 * 1024 * 1024,
                          offset <= image.range.upperBound, length <= image.range.upperBound - offset else { throw InspectionFailure.malformed }
                    signature = offset..<(offset + length)
                }
                command += size // ExecutablePreflight already validated every command bound.
            }
            guard let signature else { return Image(range: image.range, signatureRange: nil, blobs: [:]) }
            let bytes = Data(data[signature])
            func blobWord(_ at: Int) throws -> UInt32 {
                guard let value = MachOReader.u32(bytes, at: at, bigEndian: true) else { throw InspectionFailure.malformed }
                return value
            }
            let length = Int(try blobWord(4)), slots = Int(try blobWord(8))
            guard try blobWord(0) == 0xfade0cc0, slots > 0, slots <= 32,
                  length >= 12 + slots * 8, length <= bytes.count,
                  bytes.dropFirst(length).allSatisfy({ $0 == 0 }) else { throw InspectionFailure.malformed }
            var blobs: [UInt32: Data] = [:]
            var ranges: [Range<Int>] = []
            for index in 0..<slots {
                let type = try blobWord(12 + index * 8), start = Int(try blobWord(16 + index * 8))
                guard blobs[type] == nil, start >= 12 + slots * 8, start <= length - 8 else { throw InspectionFailure.malformed }
                let size = Int(try blobWord(start + 4))
                guard size >= 8, size <= length - start else { throw InspectionFailure.malformed }
                let range = start..<(start + size)
                guard !ranges.contains(where: { $0.overlaps(range) }) else { throw InspectionFailure.malformed }
                let magic = try blobWord(start)
                if type == 5 && magic != 0xfade7171 || type == 7 && magic != 0xfade7172 { throw InspectionFailure.malformed }
                ranges.append(range)
                blobs[type] = bytes.subdata(in: range)
            }
            return Image(range: image.range, signatureRange: signature, blobs: blobs)
        }
    }
}
