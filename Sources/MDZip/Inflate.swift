import Foundation

/// A bounded raw-DEFLATE decoder (RFC 1951), after zlib's `puff.c`.
///
/// It exists so reading can stop the moment an entry produces more bytes than its
/// declared size, and so a truncated or damaged stream fails instead of looping.
enum Inflate {
    enum Failure: Error {
        /// The stream is damaged or not DEFLATE.
        case invalid
        /// The input ended before the final block.
        case truncated
        /// The output would exceed the limit.
        case limit
    }

    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]
        init(symbolCount: Int) { symbol = [Int](repeating: 0, count: symbolCount) }
    }

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                             3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                          257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                          8193, 12289, 16385, 24577]
    private static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                           7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let clOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixed: (lit: Huffman, dist: Huffman) = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        var lit = Huffman(symbolCount: 288)
        _ = construct(&lit, lengths, 288)
        var dist = Huffman(symbolCount: 30)
        _ = construct(&dist, [Int](repeating: 5, count: 30), 30)
        return (lit, dist)
    }()

    /// Builds the decoding tables. Returns 0 for a complete code, a positive number for an
    /// incomplete one, and a negative number for an over-subscribed one.
    private static func construct(_ h: inout Huffman, _ lengths: [Int], _ n: Int) -> Int {
        for i in 0..<16 { h.count[i] = 0 }
        for s in 0..<n { h.count[lengths[s]] += 1 }
        if h.count[0] == n { return 0 }
        var left = 1
        for len in 1..<16 {
            left <<= 1
            left -= h.count[len]
            if left < 0 { return left }
        }
        var offs = [Int](repeating: 0, count: 16)
        for len in 1..<15 { offs[len + 1] = offs[len] + h.count[len] }
        for s in 0..<n where lengths[s] != 0 {
            h.symbol[offs[lengths[s]]] = s
            offs[lengths[s]] += 1
        }
        return left
    }

    private struct State {
        let input: UnsafeBufferPointer<UInt8>
        var pos = 0
        var bitBuf: UInt32 = 0
        var bitCount = 0
        var out: [UInt8] = []
        let limit: Int

        init(input: UnsafeBufferPointer<UInt8>, limit: Int) {
            self.input = input
            self.limit = limit
        }

        mutating func bits(_ need: Int) throws -> Int {
            var val = bitBuf
            while bitCount < need {
                guard pos < input.count else { throw Failure.truncated }
                val |= UInt32(input[pos]) << UInt32(bitCount)
                pos += 1
                bitCount += 8
            }
            bitBuf = val >> UInt32(need)
            bitCount -= need
            return Int(val & ((UInt32(1) << UInt32(need)) &- 1))
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1...15 {
                code |= try bits(1)
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.invalid
        }

        mutating func append(_ b: UInt8) throws {
            if out.count >= limit { throw Failure.limit }
            out.append(b)
        }
    }

    /// Decompresses a raw DEFLATE stream. Throws `Failure.limit` as soon as the output would
    /// pass `limit` bytes, without producing the rest.
    static func inflate(_ input: UnsafeBufferPointer<UInt8>, limit: Int, expectedSize: Int) throws -> [UInt8] {
        var s = State(input: input, limit: limit)
        s.out.reserveCapacity(min(expectedSize, limit, 64 << 20))
        var last = 0
        repeat {
            last = try s.bits(1)
            let type = try s.bits(2)
            switch type {
            case 0: try stored(&s)
            case 1: try codes(&s, fixed.lit, fixed.dist)
            case 2: try dynamic(&s)
            default: throw Failure.invalid
            }
        } while last == 0
        return s.out
    }

    private static func stored(_ s: inout State) throws {
        s.bitBuf = 0
        s.bitCount = 0
        guard s.pos + 4 <= s.input.count else { throw Failure.truncated }
        let len = Int(s.input[s.pos]) | (Int(s.input[s.pos + 1]) << 8)
        let nlen = Int(s.input[s.pos + 2]) | (Int(s.input[s.pos + 3]) << 8)
        guard len == (~nlen & 0xFFFF) else { throw Failure.invalid }
        s.pos += 4
        guard s.pos + len <= s.input.count else { throw Failure.truncated }
        if s.out.count + len > s.limit { throw Failure.limit }
        s.out.append(contentsOf: UnsafeBufferPointer(rebasing: s.input[s.pos..<(s.pos + len)]))
        s.pos += len
    }

    private static func codes(_ s: inout State, _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            var symbol = try s.decode(lit)
            if symbol < 256 {
                try s.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                symbol -= 257
                guard symbol < 29 else { throw Failure.invalid }
                let len = lengthBase[symbol] + (try s.bits(lengthExtra[symbol]))
                let dsym = try s.decode(dist)
                guard dsym < 30 else { throw Failure.invalid }
                let d = distBase[dsym] + (try s.bits(distExtra[dsym]))
                guard d <= s.out.count else { throw Failure.invalid }
                if s.out.count + len > s.limit { throw Failure.limit }
                var from = s.out.count - d
                for _ in 0..<len {
                    s.out.append(s.out[from])
                    from += 1
                }
            }
        }
    }

    private static func dynamic(_ s: inout State) throws {
        let nlen = try s.bits(5) + 257
        let ndist = try s.bits(5) + 1
        let ncode = try s.bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw Failure.invalid }
        var lengths = [Int](repeating: 0, count: 320)
        for i in 0..<ncode { lengths[clOrder[i]] = try s.bits(3) }
        var lencode = Huffman(symbolCount: 320)
        guard construct(&lencode, lengths, 19) == 0 else { throw Failure.invalid }
        var index = 0
        while index < nlen + ndist {
            var symbol = try s.decode(lencode)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
            } else {
                var len = 0
                if symbol == 16 {
                    guard index > 0 else { throw Failure.invalid }
                    len = lengths[index - 1]
                    symbol = 3 + (try s.bits(2))
                } else if symbol == 17 {
                    symbol = 3 + (try s.bits(3))
                } else {
                    symbol = 11 + (try s.bits(7))
                }
                guard index + symbol <= nlen + ndist else { throw Failure.invalid }
                for _ in 0..<symbol {
                    lengths[index] = len
                    index += 1
                }
            }
        }
        guard lengths[256] != 0 else { throw Failure.invalid }
        var lit = Huffman(symbolCount: 320)
        var err = construct(&lit, lengths, nlen)
        if err != 0 && (err < 0 || nlen != lit.count[0] + lit.count[1]) { throw Failure.invalid }
        var distLengths = Array(lengths[nlen..<(nlen + ndist)])
        distLengths += [Int](repeating: 0, count: 32 - distLengths.count)
        var dist = Huffman(symbolCount: 32)
        err = construct(&dist, distLengths, ndist)
        if err != 0 && (err < 0 || ndist != dist.count[0] + dist.count[1]) { throw Failure.invalid }
        try codes(&s, lit, dist)
    }
}
