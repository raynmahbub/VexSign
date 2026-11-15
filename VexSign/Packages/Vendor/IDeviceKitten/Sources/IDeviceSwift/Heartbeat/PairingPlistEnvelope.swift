// SPDX-License-Identifier: MIT
// VexSign local extension; retain the IDeviceKit wrapper LICENSE.
// Independently written, bounded preflight for the two flat pairing plist schemas.
// Reject graphs/duplicate keys BEFORE Foundation and the native parser see the input.
import Foundation

internal enum PairingPlistEnvelope {
    static func validate(_ data: Data) throws {
        if data.starts(with: Data("bplist00".utf8)) {
            try validateBinary(Array(data))
        } else {
            guard let text = String(data: data, encoding: .utf8),
                  !text.localizedCaseInsensitiveContains("<!ENTITY"),
                  !text.contains("<![") else { throw PairingRecordError.malformed }
            let delegate = FlatXMLPairingPlist()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = delegate
            guard parser.parse(), delegate.isComplete else { throw PairingRecordError.malformed }
        }
    }

    private static func validateBinary(_ bytes: [UInt8]) throws {
        guard bytes.count >= 40 else { throw PairingRecordError.malformed }
        let trailer = bytes.count - 32
        let offsetWidth = Int(bytes[trailer + 6])
        let refWidth = Int(bytes[trailer + 7])
        guard [1, 2, 4, 8].contains(offsetWidth), [1, 2, 4, 8].contains(refWidth) else {
            throw PairingRecordError.malformed
        }
        func integer(_ offset: Int, _ width: Int) throws -> Int {
            guard offset >= 0, width > 0, width <= 8, offset <= bytes.count - width else {
                throw PairingRecordError.malformed
            }
            let number = bytes[offset..<(offset + width)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard number <= UInt64(Int.max) else { throw PairingRecordError.malformed }
            return Int(number)
        }
        let count = try integer(trailer + 8, 8)
        let root = try integer(trailer + 16, 8)
        let table = try integer(trailer + 24, 8)
        guard (1...4096).contains(count), root < count, table >= 8, table < trailer,
              count <= (trailer - table) / offsetWidth else { throw PairingRecordError.malformed }
        let offsets = try (0..<count).map { try integer(table + $0 * offsetWidth, offsetWidth) }
        guard Set(offsets).count == count, offsets.allSatisfy({ $0 >= 8 && $0 < table }) else {
            throw PairingRecordError.malformed
        }
        func payload(_ offset: Int) throws -> (start: Int, length: Int) {
            let inline = Int(bytes[offset] & 15)
            if inline < 15 { return (offset + 1, inline) }
            guard offset + 1 < table, bytes[offset + 1] >> 4 == 1, bytes[offset + 1] & 15 <= 3 else {
                throw PairingRecordError.malformed
            }
            let width = 1 << Int(bytes[offset + 1] & 15)
            return (offset + 2 + width, try integer(offset + 2, width))
        }
        func string(_ index: Int) throws -> String {
            let offset = offsets[index]
            let kind = bytes[offset] >> 4
            guard kind == 5 || kind == 6 else { throw PairingRecordError.malformed }
            let value = try payload(offset)
            let multiplier = kind == 6 ? 2 : 1
            guard value.length <= 128, value.start <= table,
                  value.length <= (table - value.start) / multiplier,
                  let text = String(bytes: bytes[value.start..<(value.start + value.length * multiplier)],
                                    encoding: kind == 6 ? .utf16BigEndian : .ascii),
                  !text.isEmpty, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw PairingRecordError.malformed
            }
            return text
        }
        var spans: [(start: Int, end: Int)] = []
        for (index, offset) in offsets.enumerated() {
            let marker = bytes[offset]
            let kind = marker >> 4
            var end: Int
            switch kind {
            case 0 where marker == 8 || marker == 9: end = offset + 1
            case 1 where marker & 15 <= 3: end = offset + 1 + (1 << Int(marker & 15))
            case 2 where marker == 0x22 || marker == 0x23: end = offset + 1 + (1 << Int(marker & 15))
            case 4, 5, 6:
                let value = try payload(offset)
                let multiplier = kind == 6 ? 2 : 1
                guard value.start <= table, value.length <= (table - value.start) / multiplier else {
                    throw PairingRecordError.malformed
                }
                end = value.start + value.length * multiplier
            case 13 where index == root:
                let dictionary = try payload(offset)
                guard dictionary.length <= 128, dictionary.start <= table,
                      dictionary.length <= (table - dictionary.start) / (2 * refWidth) else {
                    throw PairingRecordError.malformed
                }
                end = dictionary.start + dictionary.length * 2 * refWidth
                var keys: Set<String> = []
                for pair in 0..<dictionary.length {
                    let key = try integer(dictionary.start + pair * refWidth, refWidth)
                    let value = try integer(dictionary.start + (pair + dictionary.length) * refWidth, refWidth)
                    guard key < count, value < count, value != root,
                          keys.insert(try string(key)).inserted else { throw PairingRecordError.malformed }
                }
            default: throw PairingRecordError.malformed // no arrays, nested dictionaries, URLs, UIDs or cycles
            }
            guard end <= table else { throw PairingRecordError.malformed }
            spans.append((offset, end))
        }
        guard bytes[offsets[root]] >> 4 == 13 else { throw PairingRecordError.malformed }
        let ordered = spans.sorted { $0.start < $1.start }
        for index in ordered.indices.dropFirst() where ordered[index - 1].end > ordered[index].start {
            throw PairingRecordError.malformed
        }
    }
}

private final class FlatXMLPairingPlist: NSObject, XMLParserDelegate {
    private var elements: [String] = []
    private var keys: Set<String> = []
    private var keyText = ""
    private var expectsKey = true
    private var rootSeen = false
    private var rejected = false
    var isComplete: Bool { rootSeen && elements.isEmpty && expectsKey && !rejected }

    private func reject(_ parser: XMLParser) { rejected = true; parser.abortParsing() }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch elements.count {
        case 0:
            guard !rootSeen, element == "plist", attributes == ["version": "1.0"] else { reject(parser); return }
            rootSeen = true
        case 1:
            guard elements == ["plist"], element == "dict", attributes.isEmpty else { reject(parser); return }
        case 2:
            guard elements.last == "dict", attributes.isEmpty else { reject(parser); return }
            if expectsKey {
                guard element == "key", keys.count < 128 else { reject(parser); return }
                keyText = ""
            } else {
                guard ["string", "data", "integer", "real", "true", "false"].contains(element) else { reject(parser); return }
            }
        default: reject(parser); return
        }
        elements.append(element)
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) {
        if elements.last == "key" {
            keyText += text
            if keyText.utf8.count > 128 { reject(parser) }
        } else if elements.count < 3 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reject(parser)
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard elements.last == element else { reject(parser); return }
        if elements.count == 3 {
            if element == "key" {
                guard !keyText.isEmpty, !keyText.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      keys.insert(keyText).inserted else { reject(parser); return }
            }
            expectsKey.toggle()
        } else if element == "dict" && !expectsKey { reject(parser); return }
        elements.removeLast()
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) { reject(parser) }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
