import Foundation

/// What an archive entry is. Only `file` and `directory` are ever read or followed.
public enum MDZipEntryKind: Sendable, Hashable {
    /// A regular file.
    case file
    /// A directory entry (its name ends in `/`).
    case directory
    /// A symbolic link. It is never followed (Section 13.1).
    case symlink
    /// Another special file (device, FIFO, socket). It is never read.
    case special
}

/// One central-directory record, validated.
struct ZipRecord: Sendable {
    var name: String
    var method: UInt16
    var flags: UInt16
    var crc32: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var localOffset: UInt64
    var dataOffset: UInt64
    var kind: MDZipEntryKind
    var madeBy: UInt16
    var externalAttributes: UInt32
    var dosTime: UInt16
    var dosDate: UInt16

    var usesUTF8Flag: Bool { flags & 0x0800 != 0 }
}

/// Reads the ZIP central directory. The central directory is the authority on the
/// entries (Section 4); every entry it lists is returned or the archive is rejected, so
/// nothing is hidden.
enum ZipReader {
    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EocdSignature: UInt32 = 0x0606_4B50
    private static let cdSignature: UInt32 = 0x0201_4B50
    private static let localSignature: UInt32 = 0x0403_4B50

    private static func invalid(_ message: String) -> MDZipError {
        MDZipError(.zipInvalid, message)
    }

    static func readDirectory(_ data: Data, limits: MDZipLimits) throws -> [ZipRecord] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [ZipRecord] in
            try parse(raw, limits: limits)
        }
    }

    private static func parse(_ buf: UnsafeRawBufferPointer, limits: MDZipLimits) throws -> [ZipRecord] {
        let size = buf.count
        func u16(_ o: Int) -> UInt16 { UInt16(littleEndian: buf.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
        func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
        func u64(_ o: Int) -> UInt64 { UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }

        guard size >= 22 else { throw invalid("the file is too small to be a ZIP archive") }

        // End of central directory record: the last one whose comment runs to the end of the file.
        var eocd = -1
        var p = size - 22
        let lowest = max(0, size - 22 - 65_535)
        while p >= lowest {
            if u32(p) == eocdSignature, p + 22 + Int(u16(p + 20)) == size { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw invalid("no end of central directory record found; not a ZIP archive") }

        var entryCount = UInt64(u16(eocd + 10))
        var cdSize = UInt64(u32(eocd + 12))
        var cdOffset = UInt64(u32(eocd + 16))
        let disk = u16(eocd + 4), cdDisk = u16(eocd + 6)
        var endOfCDArea = UInt64(eocd)

        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            guard eocd >= 20, u32(eocd - 20) == zip64LocatorSignature else {
                throw invalid("ZIP64 values are used but the ZIP64 locator is missing")
            }
            let recordOffset = u64(eocd - 20 + 8)
            guard recordOffset <= UInt64(size) - 56, u32(Int(recordOffset)) == zip64EocdSignature else {
                throw invalid("the ZIP64 end of central directory record is missing")
            }
            let r = Int(recordOffset)
            guard u32(r + 16) == 0, u32(r + 20) == 0 else { throw invalid("multi-disk archives are not supported") }
            entryCount = u64(r + 32)
            cdSize = u64(r + 40)
            cdOffset = u64(r + 48)
            endOfCDArea = recordOffset
        } else if disk != 0 || cdDisk != 0 {
            throw invalid("multi-disk archives are not supported")
        }

        guard cdSize <= endOfCDArea, cdOffset <= endOfCDArea - cdSize else {
            throw invalid("the central directory lies outside the file")
        }
        if entryCount > UInt64(limits.maxEntries) {
            throw MDZipError(.limitExceeded, "the archive lists \(entryCount) entries; the limit is \(limits.maxEntries)")
        }
        guard entryCount <= cdSize / 46 else { throw invalid("the central directory is smaller than its entry count") }

        var records: [ZipRecord] = []
        records.reserveCapacity(Int(entryCount))
        var pos = Int(cdOffset)
        let cdEnd = Int(cdOffset + cdSize)
        var totalDeclared: UInt64 = 0

        for _ in 0..<Int(entryCount) {
            guard pos + 46 <= cdEnd, u32(pos) == cdSignature else {
                throw invalid("a central directory record is damaged")
            }
            let madeBy = u16(pos + 4)
            let flags = u16(pos + 8)
            let method = u16(pos + 10)
            let dosTime = u16(pos + 12), dosDate = u16(pos + 14)
            let crc = u32(pos + 16)
            var compressed = UInt64(u32(pos + 20))
            var uncompressed = UInt64(u32(pos + 24))
            let nameLen = Int(u16(pos + 28)), extraLen = Int(u16(pos + 30)), commentLen = Int(u16(pos + 32))
            let diskStart = u16(pos + 34)
            let external = u32(pos + 38)
            var localOffset = UInt64(u32(pos + 42))
            let next = pos + 46 + nameLen + extraLen + commentLen
            guard next <= cdEnd else { throw invalid("a central directory record is damaged") }

            // ZIP64 extra field: fills in only the values the record marks as 0xFFFFFFFF.
            var needsDisk = diskStart == 0xFFFF
            if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF || needsDisk {
                var e = pos + 46 + nameLen
                let extraEnd = e + extraLen
                var found = false
                while e + 4 <= extraEnd {
                    let id = u16(e), len = Int(u16(e + 2))
                    guard e + 4 + len <= extraEnd else { throw invalid("an extra field is damaged") }
                    if id == 0x0001 {
                        var q = e + 4
                        let end = e + 4 + len
                        func take() throws -> UInt64 {
                            guard q + 8 <= end else { throw invalid("the ZIP64 extra field is too short") }
                            defer { q += 8 }
                            return u64(q)
                        }
                        if uncompressed == 0xFFFF_FFFF { uncompressed = try take() }
                        if compressed == 0xFFFF_FFFF { compressed = try take() }
                        if localOffset == 0xFFFF_FFFF { localOffset = try take() }
                        if needsDisk {
                            guard q + 4 <= end else { throw invalid("the ZIP64 extra field is too short") }
                            needsDisk = false
                        }
                        found = true
                        break
                    }
                    e += 4 + len
                }
                guard found else { throw invalid("a ZIP64 value is marked but the ZIP64 extra field is missing") }
            }
            if diskStart != 0 && diskStart != 0xFFFF { throw invalid("multi-disk archives are not supported") }

            // Names are UTF-8 whether or not the flag is set (Section 4).
            let nameBytes = Data(bytes: buf.baseAddress!.advanced(by: pos + 46), count: nameLen)
            guard let name = MDZipText.decode(nameBytes) else {
                throw MDZipError(.pathInvalid, "an entry name is not valid UTF-8")
            }

            if flags & 0x0001 != 0 || flags & 0x0040 != 0 || flags & 0x2000 != 0 || method == 99 {
                throw MDZipError(.zipEncrypted, "the entry is encrypted", path: name)
            }
            guard method == 0 || method == 8 else {
                throw MDZipError(.zipInvalid, "the entry uses compression method \(method); only 0 and 8 are supported",
                                 path: name)
            }

            var kind: MDZipEntryKind = name.hasSuffix("/") ? .directory : .file
            let host = madeBy >> 8
            if host == 3 || host == 19 { // Unix or macOS: the upper 16 bits hold st_mode
                switch (external >> 16) & 0xF000 {
                case 0xA000: kind = .symlink
                case 0x8000, 0x4000, 0: break
                default: kind = .special
                }
            }
            if kind == .directory && uncompressed != 0 {
                throw MDZipError(.zipInvalid, "a directory entry has content", path: name)
            }
            if method == 0 && compressed != uncompressed {
                throw MDZipError(.zipInvalid, "a stored entry's compressed and uncompressed sizes differ", path: name)
            }

            // Declared limits (Section 13.1). The bytes actually decompressed are checked on read.
            if uncompressed > limits.maxEntryBytes {
                throw MDZipError(.limitExceeded, "an entry declares \(uncompressed) bytes; the limit is \(limits.maxEntryBytes)",
                                 path: name)
            }
            let (sum, overflow) = totalDeclared.addingReportingOverflow(uncompressed)
            totalDeclared = sum
            if overflow || totalDeclared > limits.maxTotalBytes {
                throw MDZipError(.limitExceeded, "the entries declare more than \(limits.maxTotalBytes) bytes in total")
            }
            if method == 8, uncompressed > limits.ratioAppliesAboveBytes {
                if compressed == 0 || uncompressed / compressed > UInt64(limits.maxCompressionRatio) {
                    throw MDZipError(.limitExceeded,
                                     "the entry's compression ratio is above \(limits.maxCompressionRatio):1", path: name)
                }
            }

            records.append(ZipRecord(name: name, method: method, flags: flags, crc32: crc, compressedSize: compressed,
                                     uncompressedSize: uncompressed, localOffset: localOffset, dataOffset: 0,
                                     kind: kind, madeBy: madeBy, externalAttributes: external,
                                     dosTime: dosTime, dosDate: dosDate))
            pos = next
        }

        // Local headers and data: each entry's bytes must sit before the central directory
        // and must not overlap any other entry's (that is how a few KB claim gigabytes).
        for i in records.indices {
            let lo = records[i].localOffset
            guard lo <= cdOffset, cdOffset - lo >= 30, u32(Int(lo)) == localSignature else {
                throw MDZipError(.zipInvalid, "an entry has no local header", path: records[i].name)
            }
            let l = Int(lo)
            let lflags = u16(l + 6), lmethod = u16(l + 8)
            guard lmethod == records[i].method, (lflags & 1) == (records[i].flags & 1) else {
                throw MDZipError(.zipInvalid, "an entry's local header disagrees with the central directory",
                                 path: records[i].name)
            }
            let data = lo + 30 + UInt64(u16(l + 26)) + UInt64(u16(l + 28))
            guard data <= cdOffset, records[i].compressedSize <= cdOffset - data else {
                throw MDZipError(.zipInvalid, "an entry's data runs past the central directory", path: records[i].name)
            }
            records[i].dataOffset = data
        }
        let order = records.indices.sorted { records[$0].localOffset < records[$1].localOffset }
        var previousEnd: UInt64 = 0
        for i in order {
            guard records[i].localOffset >= previousEnd else {
                throw MDZipError(.zipInvalid, "entries share data (overlapping entries)", path: records[i].name)
            }
            previousEnd = records[i].dataOffset + records[i].compressedSize
        }
        return records
    }

    /// Returns an entry's bytes. Decompression stops as soon as the entry produces more than
    /// its declared size.
    static func read(_ record: ZipRecord, from data: Data) throws -> Data {
        guard record.kind != .directory else { return Data() }
        guard record.uncompressedSize <= UInt64(Int.max), record.dataOffset <= UInt64(Int.max),
              record.compressedSize <= UInt64(Int.max) else {
            throw MDZipError(.limitExceeded, "the entry is too large", path: record.name)
        }
        let start = Int(record.dataOffset)
        let compressedCount = Int(record.compressedSize)
        let expected = Int(record.uncompressedSize)
        let output: Data
        if record.method == 0 {
            let base = data.startIndex
            output = Data(data[(base + start)..<(base + start + compressedCount)])
        } else {
            let bytes: [UInt8]
            do {
                bytes = try data.withUnsafeBytes { raw -> [UInt8] in
                    let all = raw.bindMemory(to: UInt8.self)
                    let region = UnsafeBufferPointer(rebasing: all[start..<(start + compressedCount)])
                    return try Inflate.inflate(region, limit: expected, expectedSize: expected)
                }
            } catch Inflate.Failure.limit {
                throw MDZipError(.limitExceeded, "the entry expands to more than its declared \(expected) bytes",
                                 path: record.name)
            } catch {
                throw MDZipError(.zipInvalid, "the entry's compressed data is damaged", path: record.name)
            }
            output = Data(bytes)
        }
        guard output.count == expected else {
            throw MDZipError(.zipInvalid, "the entry is shorter than its declared \(expected) bytes", path: record.name)
        }
        guard CRC32.checksum(output) == record.crc32 else {
            throw MDZipError(.zipInvalid, "the entry's CRC-32 does not match", path: record.name)
        }
        return output
    }
}
