import Foundation
import ZIPFoundation

/// Identifies this library in the manifests it writes (`producer.core`, Section 6.1).
public enum MDZipCore {
    public static let name = "mdzip-core-swift"
    public static let version = "0.1.0"
    public static let url = "https://github.com/mdzip-project/mdzip-core-swift"
    /// The specification version written to `spec.version`.
    public static let specVersion = "1.2.1"
}

/// An entry ready to be written.
struct ZipWriteEntry {
    var path: String
    var kind: MDZipEntryKind // .file, .directory or .symlink (kept from an existing archive)
    var data: Data
    var compress: Bool
}

/// Writes archives with ZIPFoundation, which supplies DEFLATE and the ZIP structures.
///
/// ZIPFoundation writes only methods 0 and 8, sets the UTF-8 flag (bit 11) on every name,
/// and adds ZIP64 records only when a value does not fit without them.
enum ZipWriter {
    static func write(_ entries: [ZipWriteEntry], date: Date) throws -> Data {
        let archive: Archive
        do {
            archive = try Archive(data: Data(), accessMode: .create)
        } catch {
            throw MDZipError(.io, "cannot create an in-memory archive: \(error)")
        }
        for entry in entries {
            let payload = entry.data
            let provider: Provider = { position, size in
                let start = Int(position)
                guard start <= payload.count else { return Data() }
                let base = payload.startIndex
                return payload.subdata(in: (base + start)..<(base + min(payload.count, start + size)))
            }
            do {
                switch entry.kind {
                case .directory:
                    let name = entry.path.hasSuffix("/") ? entry.path : entry.path + "/"
                    try archive.addEntry(with: name, type: .directory, uncompressedSize: Int64(0), modificationDate: date,
                                         compressionMethod: .none, provider: { (_: Int64, _: Int) -> Data in Data() })
                case .symlink:
                    try archive.addEntry(with: entry.path, type: .symlink, uncompressedSize: Int64(payload.count),
                                         modificationDate: date, compressionMethod: .none, provider: provider)
                default:
                    try archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(payload.count),
                                         modificationDate: date,
                                         compressionMethod: entry.compress && payload.count > 0 ? .deflate : .none,
                                         provider: provider)
                }
            } catch {
                throw MDZipError(.io, "cannot write \"\(entry.path)\": \(error)", path: entry.path)
            }
        }
        guard let out = archive.data else { throw MDZipError(.io, "cannot finish the archive") }
        return out
    }

    private static let alreadyCompressed: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "zip", "gz", "bz2", "xz", "zst", "7z", "mdz",
        "mp3", "mp4", "m4a", "aac", "ogg", "opus", "webm", "mov", "woff", "woff2", "pdf", "docx", "xlsx", "pptx",
        "jar", "epub",
    ]

    /// Small files and formats that are already compressed are stored; the rest are deflated.
    static func shouldCompress(path: String, size: Int) -> Bool {
        if size < 64 { return false }
        guard let dot = path.lastIndex(of: "."), path[dot...].count > 1 else { return true }
        return !alreadyCompressed.contains(MDZipPath.asciiLowercased(String(path[path.index(after: dot)...])))
    }
}

enum MDZipTimestamp {
    /// RFC 3339 in UTC, for example `2026-03-08T14:30:00Z`.
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
}

/// Assembles the entries of a new or edited archive into bytes, after checking them.
enum Assembler {
    static func assemble(_ entries: [ZipWriteEntry], date: Date) throws -> Data {
        try MDZipArchive.checkNames(entries.map { $0.kind == .directory && !$0.path.hasSuffix("/") ? $0.path + "/" : $0.path })
        return try ZipWriter.write(entries, date: date)
    }

    /// The `producer.core` object for this library.
    static func producerCore() -> MDZipJSON {
        var core = MDZipJSONObject()
        core["name"] = .string(MDZipCore.name)
        core["version"] = .string(MDZipCore.version)
        core["url"] = .string(MDZipCore.url)
        return .object(core)
    }
}

/// Markdown text helpers.
enum MDZipMarkdown {
    /// The first level-1 ATX heading, for a default title.
    static func firstHeading(_ text: String) -> String? {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            guard line.hasPrefix("# ") else { continue }
            var title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            while title.hasSuffix("#") { title.removeLast() }
            title = title.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// CRLF to LF (Section 12.2: producers SHOULD write LF in Markdown they create or modify).
    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
