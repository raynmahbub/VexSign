import Foundation

/// Deliberately small definite-length DER reader for the supported CMS subset.
/// No BER indefinite lengths, high tag numbers, detached/chunked content or
/// generic unbounded recursive ASN.1 decoding. All failures are fixed errors.
struct NativeProfileDER {
    struct Node {
        let tag: UInt8
        let content: Data
        let encoded: Data
        func children(tag expected: UInt8, limit: Int = 32, sorted: Bool = false) throws -> [Node] {
            guard tag == expected else { throw NativeProfileValidationError.cmsRejected }
            var reader = NativeProfileDER(data: content)
            var nodes: [Node] = []
            while !reader.finished {
                guard nodes.count < limit else { throw NativeProfileValidationError.cmsRejected }
                let node = try reader.read()
                if sorted, let previous = nodes.last {
                    guard previous.encoded.lexicographicallyPrecedes(node.encoded) else { throw NativeProfileValidationError.cmsRejected }
                }
                nodes.append(node)
            }
            return nodes
        }
    }
    private let bytes: [UInt8]
    private var offset = 0
    init(data: Data) { bytes = Array(data) }
    var finished: Bool { offset == bytes.count }
    mutating func read() throws -> Node {
        let start = offset
        guard offset + 2 <= bytes.count else { throw NativeProfileValidationError.cmsRejected }
        let tag = bytes[offset]; offset += 1
        guard tag & 0x1f != 0x1f, tag != 0 else { throw NativeProfileValidationError.cmsRejected }
        let first = bytes[offset]; offset += 1
        let length: Int
        if first < 128 { length = Int(first) }
        else {
            let count = Int(first & 0x7f)
            guard count > 0, count <= 4, count <= bytes.count - offset, bytes[offset] != 0 else { throw NativeProfileValidationError.cmsRejected }
            var value = 0
            for _ in 0..<count { value = (value << 8) | Int(bytes[offset]); offset += 1 }
            guard value >= 128 else { throw NativeProfileValidationError.cmsRejected }
            length = value
        }
        guard length <= bytes.count - offset else { throw NativeProfileValidationError.cmsRejected }
        let content = Data(bytes[offset..<(offset + length)]); offset += length
        return Node(tag: tag, content: content, encoded: Data(bytes[start..<offset]))
    }
    static func one(_ data: Data, tag: UInt8) throws -> Node {
        var reader = NativeProfileDER(data: data)
        let node = try reader.read()
        guard node.tag == tag, reader.finished else { throw NativeProfileValidationError.cmsRejected }
        return node
    }
    /// Bounded structural walk for signed attributes, including unknown values:
    /// never leave nested indefinite/high-tag encodings unexamined. Primitive
    /// bytes are opaque unless the CMS parser assigns them security semantics.
    static func validateConstructed(_ node: Node, depth: Int = 0, budget: inout Int) throws {
        guard depth <= 12, budget > 0 else { throw NativeProfileValidationError.cmsRejected }
        budget -= 1
        if node.tag & 0x20 != 0 {
            for child in try node.children(tag: node.tag, limit: 64, sorted: node.tag == 0x31) {
                try validateConstructed(child, depth: depth + 1, budget: &budget)
            }
        }
    }

    static func positiveInteger(_ node: Node) throws {
        let bytes = Array(node.content)
        guard node.tag == 0x02, !bytes.isEmpty, bytes.count <= 32,
              bytes[0] & 0x80 == 0, bytes.contains(where: { $0 != 0 }),
              !(bytes.count > 1 && bytes[0] == 0 && bytes[1] & 0x80 == 0) else { throw NativeProfileValidationError.cmsRejected }
    }
}
