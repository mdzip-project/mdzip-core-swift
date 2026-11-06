import Foundation

/// CRC-32 (IEEE 802.3), as used by ZIP.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            checksum(raw.bindMemory(to: UInt8.self))
        }
    }
}
