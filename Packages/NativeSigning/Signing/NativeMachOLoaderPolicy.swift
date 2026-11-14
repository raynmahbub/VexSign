import Foundation

/// Restrictive system-only loader envelope. It validates command forms, dependency
/// names, linkedit ranges and a legacy pointer rebase/bind dialect, NOT export/
/// chained-fixup payloads or complete dyld execution semantics. It cannot release an installation artifact.
struct NativeMachOLoaderPolicy {
    static func validate(_ data: Data) throws {
        let layout = try NativeMachOSigningLayout.inspect(data)
        let bytes = Array(data)
        func word(_ p: Int) throws -> Int {
            guard p >= 0, p <= bytes.count - 4 else { throw NativeSignedOutputError.unsupportedClaims }
            return Int(bytes[p]) | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]) << 16 | Int(bytes[p + 3]) << 24
        }
        func wide(_ p: Int) throws -> UInt64 { try UInt64(word(p)) | UInt64(word(p + 4)) << 32 }
        var commands: [(kind: Int, start: Int, size: Int)] = []
        var cursor = 32
        for _ in 0..<(try word(16)) {
            let size = try word(cursor + 4)
            commands.append((try word(cursor), cursor, size)); cursor += size
        }
        guard let linkedit = commands.first(where: { command in
            guard command.kind == 0x19 else { return false }
            return String(bytes: bytes[(command.start + 8)..<(command.start + 18)], encoding: .ascii) == "__LINKEDIT"
        }) else { throw NativeSignedOutputError.unsupportedClaims }
        let linkeditStart = try wide(linkedit.start + 40)
        func reference(_ start: Int, _ count: Int, stride: Int = 1) throws {
            guard count >= 0, stride > 0 else { throw NativeSignedOutputError.unsupportedClaims }
            if count == 0 {
                guard start == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                return
            }
            guard start >= 0, UInt64(start) >= linkeditStart, start <= layout.signatureRange.lowerBound,
                  count <= (layout.signatureRange.lowerBound - start) / stride else { throw NativeSignedOutputError.unsupportedClaims }
        }
        func string(_ command: (kind: Int, start: Int, size: Int), offset: Int) throws -> String {
            guard command.size > offset, try word(command.start + 8) == offset else { throw NativeSignedOutputError.unsupportedClaims }
            let raw = Array(bytes[(command.start + offset)..<(command.start + command.size)])
            guard let zero = raw.firstIndex(of: 0), zero > 0, raw[zero...].allSatisfy({ $0 == 0 }),
                  raw[..<zero].allSatisfy({ (33...126).contains($0) }),
                  let value = String(bytes: raw[..<zero], encoding: .ascii) else { throw NativeSignedOutputError.unsupportedClaims }
            return value
        }
        var singleton = Set<Int>(); var dependencies = Set<String>(); var dyld = false; var version = false
        var symtab: (offset: Int, symbols: Int, strings: Int, stringBytes: Int)?
        var dysymtab: Int?
        var dyldInfo: Int?
        var exportCommand: Int?
        var chainedCommand: Int?
        var dyldSegments: [NativeDyldSegment] = []
        for command in commands where command.kind == 0x19 {
            let start = Int(try wide(command.start + 40)); let length = Int(try wide(command.start + 48))
            let protection = try word(command.start + 60)
            dyldSegments.append(.init(file: start..<min(start + length, layout.signatureRange.lowerBound),
                address: try wide(command.start + 24), vmSize: try wide(command.start + 32),
                writable: protection & 2 != 0, executable: protection & 4 != 0))
        }
        for command in commands {
            try Task.checkCancellation()
            let p = command.start; let size = command.size
            switch command.kind {
            case 0x19, 0x1d, 0x80000028, 0x2c:
                break // independently validated by signing layout
            case 0xc, 0x80000018: // load / weak-load dylib
                guard size >= 32 else { throw NativeSignedOutputError.unsupportedClaims }
                let path = try string(command, offset: 24)
                guard isSystemDependency(path), dependencies.insert(path).inserted, dependencies.count <= 253 else { throw NativeSignedOutputError.unsupportedClaims }
            case 0xe: // LC_LOAD_DYLINKER
                guard !dyld, try string(command, offset: 12) == "/usr/lib/dyld" else { throw NativeSignedOutputError.unsupportedClaims }
                dyld = true
            case 0x32: // LC_BUILD_VERSION, iPhoneOS only, never simulator/MacCatalyst
                guard !version, size >= 24, try word(p + 8) == 2,
                      try word(p + 12) > 0, try word(p + 16) >= word(p + 12) else { throw NativeSignedOutputError.unsupportedClaims }
                let tools = try word(p + 20)
                guard tools <= 8, size == 24 + tools * 8 else { throw NativeSignedOutputError.unsupportedClaims }
                var seen = Set<Int>()
                for i in 0..<tools {
                    let tool = try word(p + 24 + i * 8)
                    guard (1...4).contains(tool), seen.insert(tool).inserted else { throw NativeSignedOutputError.unsupportedClaims }
                }
                version = true
            case 0x25: // LC_VERSION_MIN_IPHONEOS
                guard !version, size == 16, try word(p + 8) > 0, try word(p + 12) >= word(p + 8) else { throw NativeSignedOutputError.unsupportedClaims }
                version = true
            case 0x1b, 0x2a: // UUID / source version
                guard singleton.insert(command.kind).inserted, size == (command.kind == 0x1b ? 24 : 16) else { throw NativeSignedOutputError.unsupportedClaims }
            case 2: // LC_SYMTAB, nlist_64 + strings
                guard symtab == nil, size == 24 else { throw NativeSignedOutputError.unsupportedClaims }
                let symbols = try word(p + 12); let strings = try word(p + 16); let count = try word(p + 20)
                try reference(word(p + 8), symbols, stride: 16); try reference(strings, count)
                if count > 0 { guard bytes[strings] == 0, bytes[strings + count - 1] == 0 else { throw NativeSignedOutputError.unsupportedClaims } }
                guard symbols == 0 || count > 0 else { throw NativeSignedOutputError.unsupportedClaims }
                symtab = (try word(p + 8), symbols, strings, count)
            case 0xb: // LC_DYSYMTAB, limited no relocation/module-table dialect
                guard dysymtab == nil, size == 80 else { throw NativeSignedOutputError.unsupportedClaims }
                for field in stride(from: 32, through: 48, by: 8) {
                    guard try word(p + field) == 0, try word(p + field + 4) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                }
                for field in [64, 72] {
                    guard try word(p + field) == 0, try word(p + field + 4) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                }
                try reference(word(p + 56), word(p + 60), stride: 4)
                dysymtab = p
            case 0x80000022: // LC_DYLD_INFO_ONLY, restricted legacy streams
                guard singleton.insert(command.kind).inserted, size == 48 else { throw NativeSignedOutputError.unsupportedClaims }
                for field in stride(from: 8, through: 40, by: 8) { try reference(word(p + field), word(p + field + 4)) }
                // Weak binding/interposition remains unsupported.
                guard try word(p + 28) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                dyldInfo = p
            case 0x80000033: // LC_DYLD_EXPORTS_TRIE
                guard exportCommand == nil, size == 16 else { throw NativeSignedOutputError.unsupportedClaims }
                try reference(word(p + 8), word(p + 12)); exportCommand = p
            case 0x80000034: // Restricted uncompressed 64-bit offset chains.
                guard chainedCommand == nil, size == 16 else { throw NativeSignedOutputError.unsupportedClaims }
                try reference(word(p + 8), word(p + 12)); chainedCommand = p
            case 0x26, 0x29: // linkedit_data_command
                guard singleton.insert(command.kind).inserted, size == 16 else { throw NativeSignedOutputError.unsupportedClaims }
                try reference(word(p + 8), word(p + 12))
                let start = try word(p + 8); let length = try word(p + 12)
                let metadata = data.subdata(in: start..<(start + length))
                if command.kind == 0x26 { try NativeLinkeditMetadata.functions(metadata, image: data) }
                else { try NativeLinkeditMetadata.dataInCode(metadata, image: data) }
            default:
                // Includes RPATH, environment, reexports/upward/lazy dylibs,
                // dylib ID, thread/routines, filesets and all unknown commands.
                throw NativeSignedOutputError.unsupportedClaims
            }
        }
        guard dyld, version else { throw NativeSignedOutputError.unsupportedClaims }
        if let p = dyldInfo {
            if chainedCommand != nil {
                for field in [12, 20, 36] {
                    guard try word(p + field) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                }
            }
            func stream(_ field: Int) throws -> Data {
                let start = try word(p + field); let size = try word(p + field + 4)
                return data.subdata(in: start..<(start + size))
            }
            if exportCommand != nil {
                guard try word(p + 44) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
            }
            try NativeExportTrie.validate(stream(40), segments: dyldSegments, signatureOffset: layout.signatureRange.lowerBound)
            try NativeDyldBytecode.validate(rebase: stream(8), bind: stream(16), lazyBind: stream(32),
                image: data, segments: dyldSegments, dependencyCount: dependencies.count,
                signatureOffset: layout.signatureRange.lowerBound)
        }
        if let p = exportCommand {
            let start = try word(p + 8); let count = try word(p + 12)
            try NativeExportTrie.validate(data.subdata(in: start..<(start + count)),
                segments: dyldSegments, signatureOffset: layout.signatureRange.lowerBound)
        }
        if let p = chainedCommand {
            let start = try word(p + 8); let count = try word(p + 12)
            try NativeChainedFixups.validate(data.subdata(in: start..<(start + count)), image: data,
                segments: dyldSegments, dependencyCount: dependencies.count,
                signatureOffset: layout.signatureRange.lowerBound)
        }
        if let symtab {
            var sectionCount = 0
            for command in commands where command.kind == 0x19 { sectionCount += try word(command.start + 64) }
            for index in 0..<symtab.symbols {
                if index & 255 == 0 { try Task.checkCancellation() }
                let p = symtab.offset + index * 16
                let type = bytes[p + 4]; let section = Int(bytes[p + 5]); let ordinal = Int(bytes[p + 7])
                guard try word(p) < symtab.stringBytes, type & 0xe0 == 0,
                      [UInt8(0), 2, 14].contains(type & 0x0e),
                      (type & 0x0e == 14 ? section > 0 && section <= sectionCount : section == 0),
                      ordinal < 0xfe, ordinal <= dependencies.count else { throw NativeSignedOutputError.unsupportedClaims }
            }
        }
        if let p = dysymtab {
            guard let symtab else { throw NativeSignedOutputError.unsupportedClaims }
            let locals = try word(p + 12); let external = try word(p + 20); let undefined = try word(p + 28)
            guard try word(p + 8) == 0, try word(p + 16) == locals,
                  try word(p + 24) == locals + external, locals + external + undefined == symtab.symbols else {
                throw NativeSignedOutputError.unsupportedClaims
            }
        }
    }

    static func isSystemDependency(_ path: String) -> Bool {
        guard path.utf8.count <= 1024, path.utf8.allSatisfy({ (33...126).contains($0) }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "", !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.contains("\\"), !path.contains(":") else { return false }
        func token(_ text: String) -> Bool {
            !text.isEmpty && text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [UInt8(95), 45].contains($0) }
        }
        if parts.count == 6, Array(parts.prefix(4)) == ["", "System", "Library", "Frameworks"], parts[4] == parts[5] + ".framework" {
            return token(parts[5])
        }
        let filename: String
        if parts.count == 4, parts[1] == "usr", parts[2] == "lib" { filename = parts[3] }
        else if parts.count == 5, parts[1] == "usr", parts[2] == "lib", parts[3] == "swift" { filename = parts[4] }
        else { return false }
        guard filename.hasPrefix("lib"), filename.hasSuffix(".dylib") else { return false }
        let stem = String(filename.dropLast(6))
        return stem.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { token(String($0)) }
    }
}
