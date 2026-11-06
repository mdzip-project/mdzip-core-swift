import Foundation

/// An entry listed in an archive's central directory.
public struct MDZipEntry: Sendable, Hashable {
    /// The stored path (directory entries end in `/`).
    public let path: String
    public let kind: MDZipEntryKind
    /// The size the archive declares for the entry's content.
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64
    /// ZIP compression method: 0 (stored) or 8 (deflate).
    public let compressionMethod: UInt16

    public var isFile: Bool { kind == .file }
    public var isDirectory: Bool { kind == .directory }
}

/// An open `.mdz` archive, held in memory.
///
/// Opening checks the ZIP structure, entry names (Section 5.4), duplicate and conflicting
/// entries, and the resource limits, and rejects the archive with a coded ``MDZipError``
/// otherwise. Symbolic links and other special entries are listed but never read or followed.
///
/// Path lookups follow Section 5.4.1: case-sensitive, after NFC normalization.
public struct MDZipArchive: Sendable {
    let source: Data
    let records: [ZipRecord]
    /// The limits this archive was opened with, which also apply to reads and edits.
    public let limits: MDZipLimits
    private let fileIndex: [String: Int]
    private let directoryNames: Set<String>

    // MARK: Opening (R1)

    /// Opens an archive from its bytes.
    ///
    /// - Throws: `ERR_ZIP_INVALID`, `ERR_ZIP_ENCRYPTED`, `ERR_PATH_INVALID` (with a specific
    ///   `detail`), `ERR_DUPLICATE_PATH`, `ERR_PATH_CONFLICT` or `ERR_LIMIT_EXCEEDED`.
    public init(data: Data, limits: MDZipLimits = .default) throws {
        let records = try ZipReader.readDirectory(data, limits: limits)
        try MDZipArchive.checkNames(records.map { $0.name })
        self.source = data
        self.records = records
        self.limits = limits
        var files: [String: Int] = [:]
        var dirs: Set<String> = []
        for (i, r) in records.enumerated() {
            switch r.kind {
            case .file: files[MDZipPath.normalized(r.name)] = i
            case .directory: dirs.insert(MDZipPath.normalized(String(r.name.dropLast())))
            default: break
            }
        }
        fileIndex = files
        directoryNames = dirs
    }

    /// Opens an archive from a file on disk. The file is read into memory.
    public init(contentsOf url: URL, limits: MDZipLimits = .default) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw MDZipError(.io, "cannot read \(url.path): \(error.localizedDescription)")
        }
        try self.init(data: data, limits: limits)
    }

    /// Checks every entry name and the set of names (Section 5.4).
    static func checkNames(_ names: [String]) throws {
        var keys: [String: Bool] = [:] // NFC name without a trailing slash -> is a directory
        var fileKeys: Set<String> = []
        for name in names {
            if let code = MDZipPath.validate(entryName: name) {
                throw MDZipError(.pathInvalid, "invalid entry name (\(code.rawValue))", path: name, detail: code)
            }
            let isDir = name.hasSuffix("/")
            let key = MDZipPath.normalized(isDir ? String(name.dropLast()) : name)
            if let existing = keys[key] {
                if existing == isDir {
                    throw MDZipError(.duplicatePath, "two entries have the same path after NFC normalization",
                                     path: name)
                }
                throw MDZipError(.pathConflict, "a file and a directory have the same path", path: name)
            }
            keys[key] = isDir
            if !isDir { fileKeys.insert(key) }
        }
        // A file may not also be the directory of another entry.
        for key in keys.keys {
            var parent = ""
            let parts = MDZipPath.segments(key)
            for part in parts.dropLast() {
                parent = parent.isEmpty ? part : parent + "/" + part
                if fileKeys.contains(parent) {
                    throw MDZipError(.pathConflict, "\"\(parent)\" is both a file and a directory", path: parent)
                }
            }
        }
    }

    // MARK: Listing (R2)

    /// Every central-directory entry, in archive order.
    public var entries: [MDZipEntry] {
        records.map {
            MDZipEntry(path: $0.name, kind: $0.kind, uncompressedSize: $0.uncompressedSize,
                       compressedSize: $0.compressedSize, compressionMethod: $0.method)
        }
    }
    /// Regular files only.
    public var files: [MDZipEntry] { entries.filter { $0.kind == .file } }
    /// Directory entries (paths end in `/`).
    public var directories: [MDZipEntry] { entries.filter { $0.kind == .directory } }
    /// Symbolic links and other special entries. They are never read, followed or resolved to.
    public var specialEntries: [MDZipEntry] { entries.filter { $0.kind == .symlink || $0.kind == .special } }

    /// Whether a regular file with this path exists (NFC, case-sensitive).
    public func contains(_ path: String) -> Bool {
        fileIndex[MDZipPath.normalized(path)] != nil
    }

    /// Whether a directory entry for this path exists (with or without a trailing `/`).
    public func containsDirectory(_ path: String) -> Bool {
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        return directoryNames.contains(MDZipPath.normalized(p))
    }

    /// The file entry with this path, matched by NFC and case.
    public func entry(at path: String) -> MDZipEntry? {
        guard let i = fileIndex[MDZipPath.normalized(path)] else { return nil }
        let r = records[i]
        return MDZipEntry(path: r.name, kind: r.kind, uncompressedSize: r.uncompressedSize,
                          compressedSize: r.compressedSize, compressionMethod: r.method)
    }

    /// A file whose path differs from `path` only in case: the "did you mean" of Section 5.4.1.
    /// It is only a suggestion; lookups never use it.
    public func nearMatch(for path: String) -> String? {
        guard !contains(path) else { return nil }
        let wanted = MDZipPath.normalized(path).lowercased()
        return records.first {
            $0.kind == .file && MDZipPath.normalized($0.name).lowercased() == wanted
        }?.name
    }

    func record(at path: String) -> ZipRecord? {
        fileIndex[MDZipPath.normalized(path)].map { records[$0] }
    }

    // MARK: Reading (R2)

    /// The bytes of a file.
    ///
    /// - Throws: `ERR_ENTRY_NOT_FOUND` if there is no file with exactly this path (a differently
    ///   cased file is never substituted); `ERR_LIMIT_EXCEEDED` if the entry expands past its
    ///   declared size; `ERR_ZIP_INVALID` if its data is damaged.
    public func data(at path: String) throws -> Data {
        guard let record = record(at: path) else {
            var message = "no file named \"\(path)\""
            if let near = nearMatch(for: path) { message += "; did you mean \"\(near)\"?" }
            throw MDZipError(.entryNotFound, message, path: path)
        }
        return try ZipReader.read(record, from: source)
    }

    /// A file's content as UTF-8 text, exactly as stored (CRLF and a byte order mark are kept).
    ///
    /// - Throws: the errors of ``data(at:)``, and `ERR_TEXT_DECODING` if the bytes are not valid UTF-8.
    public func text(at path: String) throws -> String {
        let bytes = try data(at: path)
        guard let text = MDZipText.decode(bytes) else {
            throw MDZipError(.textDecoding, "\"\(path)\" is not valid UTF-8", path: path)
        }
        return text
    }

    // MARK: Manifest, entry point and mode (R2)

    /// Whether the archive has a `manifest.json` at its root.
    public var hasManifest: Bool { contains("manifest.json") }

    /// The parsed and validated manifest, or `nil` if the archive has none.
    ///
    /// - Throws: `ERR_MANIFEST_INVALID`, `ERR_VERSION_UNSUPPORTED`, `ERR_MODE_UNSUPPORTED` or
    ///   `ERR_ENTRYPOINT_INVALID` (see ``MDZipManifest/parse(_:)``). A broken manifest is
    ///   never silently ignored.
    public func manifest() throws -> MDZipManifest? {
        guard hasManifest else { return nil }
        return try MDZipManifest.parse(try data(at: "manifest.json"))
    }

    /// The effective mode: declared in the manifest, or `document` if there is no manifest or
    /// no `mode` (Section 5.7.1).
    public func mode() throws -> MDZipMode {
        try manifest()?.mode ?? .document
    }

    /// The primary Markdown file (Section 5.5), as stored in the archive.
    ///
    /// - A declared `entryPoint` that is malformed fails with `ERR_ENTRYPOINT_INVALID`, and one that
    ///   names no file fails with `ERR_ENTRYPOINT_MISSING`, including a case-only difference.
    ///   There is no fallback to `index.md` or `README.md`.
    /// - Without a declared `entryPoint`: `index.md`, else the only root-level Markdown file with
    ///   support files (README, AGENTS, LICENSE, CHANGELOG, CONTRIBUTING) set aside, else the
    ///   only root-level Markdown file if it is a support file. Otherwise `ERR_ENTRYPOINT_UNRESOLVED`.
    public func entryPoint() throws -> String {
        let declared = try manifest()?.entryPoint
        return try EntryPoint.resolve(files: files.map { $0.path }, declared: declared)
    }

    /// The cover image path if the manifest names a valid one that exists. An invalid or missing
    /// `cover` is ignored (Section 6.2); ``validate()`` reports it.
    public func cover() throws -> String? {
        guard let cover = try manifest()?.cover, let i = fileIndex[MDZipPath.normalized(cover)] else { return nil }
        return records[i].name
    }
}

/// Entry point discovery (Section 5.5).
enum EntryPoint {
    /// - Parameters:
    ///   - files: stored paths of the regular files.
    ///   - declared: the manifest's `entryPoint`, already validated and with `./` removed.
    static func resolve(files: [String], declared: String?) throws -> String {
        if let declared = declared {
            let wanted = MDZipPath.normalized(declared)
            if let hit = files.first(where: { MDZipPath.normalized($0).unicodeScalars.elementsEqual(wanted.unicodeScalars) }) {
                return hit
            }
            throw MDZipError(.entryPointMissing, "the manifest's entryPoint \"\(declared)\" is not in the archive",
                             path: declared)
        }
        let nfc = files.map { (stored: $0, key: MDZipPath.normalized($0)) }
        if let index = nfc.first(where: { $0.key == "index.md" }) { return index.stored }
        let root = nfc.filter { !$0.key.contains("/") && MDZipPath.hasMarkdownExtension($0.key) }
        let content = root.filter { !MDZipPath.isSupportFile(rootLevelName: $0.key) }
        if content.count == 1 { return content[0].stored }
        if content.isEmpty && root.count == 1 { return root[0].stored }
        throw MDZipError(.entryPointUnresolved, "no unambiguous entry point: choose one of \(root.map { $0.stored })")
    }
}
