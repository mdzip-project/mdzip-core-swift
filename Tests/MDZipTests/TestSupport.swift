import Foundation
import XCTest
@testable import MDZip

enum Fixtures {
    /// The spec fixtures, bundled as a test resource (Package.swift), so the tests find them on
    /// Linux, macOS and iOS devices or simulators alike.
    static let directory: URL = Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func archive(_ name: String, limits: MDZipLimits = .default) throws -> MDZipArchive {
        try MDZipArchive(data: data(name), limits: limits)
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name))
    }

    static func objects(_ name: String) throws -> [[String: Any]] {
        let any = try json(name)
        if let a = any as? [[String: Any]] { return a }
        return (any as! [String: Any])["cases"] as! [[String: Any]]
    }
}

/// Writes a plain ZIP (stored entries only) independently of the library under test, so tests
/// can build archives the library itself would refuse to write.
enum RawZip {
    static func make(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        for e in entries {
            let name = Array(e.name.utf8)
            let flags = name.contains(where: { $0 >= 0x80 }) ? 0x0800 : 0
            let crc = CRC32.checksum(e.data)
            let offset = UInt32(out.count)
            out += Data(le32(0x0403_4B50) + le16(20) + le16(flags) + le16(0) + le16(0) + le16(0x21)
                        + le32(crc) + le32(UInt32(e.data.count)) + le32(UInt32(e.data.count))
                        + le16(name.count) + le16(0) + name)
            out += e.data
            central += Data(le32(0x0201_4B50) + le16(20) + le16(20) + le16(flags) + le16(0) + le16(0) + le16(0x21)
                            + le32(crc) + le32(UInt32(e.data.count)) + le32(UInt32(e.data.count))
                            + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name)
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += Data(le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
                    + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        return out
    }

    static func make(names: [String], manifest: String? = nil) -> Data {
        var entries: [(name: String, data: Data)] = names.filter { $0 != "manifest.json" }.map { ($0, Data()) }
        if let m = manifest { entries.append(("manifest.json", Data(m.utf8))) }
        return make(entries)
    }
}

func sha256Hex(_ data: Data) -> String {
    // Small SHA-256 so the tests need no crypto dependency (Foundation has none on Linux).
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    var msg = [UInt8](data)
    let bitLen = UInt64(msg.count) * 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (8 * UInt64(i))) & 0xFF)) }
    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for chunk in stride(from: 0, to: msg.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = (UInt32(msg[chunk + 4 * i]) << 24) | (UInt32(msg[chunk + 4 * i + 1]) << 16)
                | (UInt32(msg[chunk + 4 * i + 2]) << 8) | UInt32(msg[chunk + 4 * i + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }
    return h.map { String(format: "%08x", $0) }.joined()
}

/// Prints a line the fixture report is built from, and asserts the result.
func report(_ id: String, _ status: String, _ note: String = "") {
    print("FIXTURE-RESULT \(id) \(status) \(note)")
}

func XCTAssertCode(_ expression: @autoclosure () throws -> Any, _ code: MDZipErrorCode,
                   file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try expression()
        XCTFail("expected \(code.rawValue), but no error was thrown", file: file, line: line)
    } catch let e as MDZipError {
        XCTAssertEqual(e.code, code, "\(e)", file: file, line: line)
    } catch {
        XCTFail("expected \(code.rawValue), got \(error)", file: file, line: line)
    }
}
