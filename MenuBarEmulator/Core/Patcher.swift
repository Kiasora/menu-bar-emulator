import Foundation

/// Applies ROM patches, the usual way ROM hacks, translations and fan mods are shared:
/// IPS (oldest, no checksums), UPS and BPS (both say which game they're for via CRC32).
enum Patcher {
    enum Format { case ips, ups, bps }

    enum PatchError: Error, Equatable {
        case unknownFormat
        case corrupt
        /// The patch is for a different game (or a different version of it).
        case wrongGame
        case noMatchingGame
    }

    static func format(of patch: Data) -> Format? {
        if patch.starts(with: Array("PATCH".utf8)) { return .ips }
        if patch.starts(with: Array("UPS1".utf8)) { return .ups }
        if patch.starts(with: Array("BPS1".utf8)) { return .bps }
        return nil
    }

    /// The game a UPS/BPS patch expects: its size and CRC32. IPS patches don't record it.
    static func requiredSource(of patch: Data) -> (size: Int, crc: UInt32)? {
        let bytes = [UInt8](patch)
        guard let format = format(of: patch), format != .ips, bytes.count >= 16 else { return nil }
        var reader = Reader(bytes: bytes, position: 4)
        guard let size = try? reader.varint() else { return nil }
        return (Int(size), reader.uint32(at: bytes.count - 12))
    }

    static func apply(_ patch: Data, to source: Data) throws -> Data {
        switch format(of: patch) {
        case .ips: return try applyIPS([UInt8](patch), [UInt8](source))
        case .ups: return try applyUPS([UInt8](patch), [UInt8](source))
        case .bps: return try applyBPS([UInt8](patch), [UInt8](source))
        case nil: throw PatchError.unknownFormat
        }
    }

    // MARK: IPS

    private static func applyIPS(_ patch: [UInt8], _ source: [UInt8]) throws -> Data {
        var out = source
        var i = 5
        func byte() throws -> Int {
            guard i < patch.count else { throw PatchError.corrupt }
            defer { i += 1 }
            return Int(patch[i])
        }
        while true {
            guard i + 3 <= patch.count else { throw PatchError.corrupt }
            if patch[i] == 0x45, patch[i + 1] == 0x4F, patch[i + 2] == 0x46 { // "EOF"
                i += 3
                if i + 3 <= patch.count { // optional final size (can truncate or zero-pad)
                    let size = Int(patch[i]) << 16 | Int(patch[i + 1]) << 8 | Int(patch[i + 2])
                    if size <= out.count { out = Array(out.prefix(size)) }
                    else { out += [UInt8](repeating: 0, count: size - out.count) }
                }
                return Data(out)
            }
            let offset = try byte() << 16 | byte() << 8 | byte()
            var length = try byte() << 8 | byte()
            var run: UInt8?
            if length == 0 { // RLE record
                length = try byte() << 8 | byte()
                run = UInt8(try byte())
            }
            if out.count < offset + length { out += [UInt8](repeating: 0, count: offset + length - out.count) }
            for k in 0..<length { out[offset + k] = try run ?? UInt8(byte()) }
        }
    }

    // MARK: UPS

    private static let maxROMSize = 1 << 30 // Above every supported cartridge size; blocks tiny malicious allocations.

    private static func applyUPS(_ patch: [UInt8], _ source: [UInt8]) throws -> Data {
        guard patch.count >= 16 else { throw PatchError.corrupt }
        var reader = Reader(bytes: patch, position: 4)
        let inputSize = Int(try reader.varint()), outputSize = Int(try reader.varint())
        let footer = patch.count - 12
        guard inputSize <= maxROMSize, outputSize <= maxROMSize,
              reader.uint32(at: footer) == crc32(source), source.count == inputSize else { throw PatchError.wrongGame }
        var out = source + [UInt8](repeating: 0, count: max(0, outputSize - source.count))
        var offset = 0
        while reader.position < footer {
            let (next, overflow) = offset.addingReportingOverflow(Int(try reader.varint()))
            guard !overflow, next <= maxROMSize else { throw PatchError.corrupt }
            offset = next
            while true {
                guard reader.position < footer, offset < maxROMSize else { throw PatchError.corrupt }
                let x = patch[reader.position]
                reader.position += 1
                if offset < out.count { out[offset] ^= x }
                offset += 1
                if x == 0 { break }
            }
        }
        out = Array(out.prefix(outputSize))
        guard reader.uint32(at: footer + 4) == crc32(out),
              reader.uint32(at: footer + 8) == crc32(patch.prefix(footer + 8)) else { throw PatchError.corrupt }
        return Data(out)
    }

    // MARK: BPS

    private static func applyBPS(_ patch: [UInt8], _ source: [UInt8]) throws -> Data {
        guard patch.count >= 16 else { throw PatchError.corrupt }
        var reader = Reader(bytes: patch, position: 4)
        let sourceSize = Int(try reader.varint()), targetSize = Int(try reader.varint())
        let metadata = Int(try reader.varint())
        let footer = patch.count - 12
        guard sourceSize <= maxROMSize, targetSize <= maxROMSize, metadata <= footer - reader.position,
              reader.uint32(at: footer) == crc32(source), source.count == sourceSize else { throw PatchError.wrongGame }
        reader.position += metadata

        var out: [UInt8] = []
        out.reserveCapacity(min(targetSize, 64 << 20))
        var sourceOffset = 0, targetOffset = 0
        while reader.position < footer {
            let data = try reader.varint()
            let length = Int(data >> 2) + 1
            guard out.count <= targetSize, length <= targetSize - out.count else { throw PatchError.corrupt }
            switch data & 3 {
            case 0: // SourceRead
                guard out.count <= source.count, length <= source.count - out.count else { throw PatchError.corrupt }
                out += source[out.count..<out.count + length]
            case 1: // TargetRead
                guard length <= footer - reader.position else { throw PatchError.corrupt }
                out += patch[reader.position..<reader.position + length]
                reader.position += length
            case 2: // SourceCopy
                let d = try reader.varint()
                let (offset, overflow) = sourceOffset.addingReportingOverflow((d & 1 == 1 ? -1 : 1) * Int(d >> 1))
                guard !overflow, offset >= 0, offset <= source.count, length <= source.count - offset else { throw PatchError.corrupt }
                sourceOffset = offset
                out += source[sourceOffset..<sourceOffset + length]
                sourceOffset += length
            default: // TargetCopy (may overlap what it's writing, so byte by byte)
                let d = try reader.varint()
                let (offset, overflow) = targetOffset.addingReportingOverflow((d & 1 == 1 ? -1 : 1) * Int(d >> 1))
                guard !overflow, offset >= 0 else { throw PatchError.corrupt }
                targetOffset = offset
                for _ in 0..<length {
                    guard targetOffset < out.count else { throw PatchError.corrupt }
                    out.append(out[targetOffset])
                    targetOffset += 1
                }
            }
        }
        guard out.count == targetSize, reader.uint32(at: footer + 4) == crc32(out),
              reader.uint32(at: footer + 8) == crc32(patch.prefix(footer + 8)) else { throw PatchError.corrupt }
        return Data(out)
    }

    // MARK: Helpers

    private struct Reader {
        let bytes: [UInt8]
        var position: Int

        /// The variable-length number encoding UPS and BPS share.
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 1
            while true {
                guard position < bytes.count, shift < 1 << 56 else { throw PatchError.corrupt }
                let x = bytes[position]
                position += 1
                value += UInt64(x & 0x7F) * shift
                if x & 0x80 != 0 {
                    guard value <= UInt64(Int.max) else { throw PatchError.corrupt }
                    return value
                }
                shift <<= 7
                value += shift
            }
        }

        func uint32(at i: Int) -> UInt32 {
            guard i >= 0, i + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
