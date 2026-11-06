import Foundation

/// Modifies an existing archive (R6): add, replace and remove entries, and update metadata.
///
/// ```swift
/// let archive = try MDZipArchive(contentsOf: url)
/// var editor = try archive.editor()
/// try editor.setFile("notes.md", text: "# Notes\n")
/// try editor.removeFile("old.md")
/// try editor.updateManifest { $0["title"] = "Second edition" }
/// try editor.save(to: url)           // atomic: on any failure the original file is untouched
/// ```
///
/// What an edit keeps:
/// - Every entry you did not change keeps its stored path and its exact bytes. Compression and
///   timestamps may change (Section 14.1); a stored entry stays stored.
/// - Every manifest member is kept, including unknown ones at any depth, in order. Duplicate
///   member names in the original are written once, with the value that readers use.
/// - The entry point still resolves to the same file. If the manifest declares none and an edit
///   would change what Section 5.5 selects, `entryPoint` is written to pin the original. Edits
///   that remove the entry point's file are rejected unless you set a new one.
/// - An archive without a manifest gets one (`spec.version`, `entryPoint`, `mode`, `producer.core`)
///   unless ``addsManifestIfMissing`` is off or its entry point is ambiguous.
public struct MDZipEditor {
    /// What to do with symbolic link entries in the archive being edited (Section 14.1: they are never silently dropped).
    public enum SymlinkPolicy: Sendable {
        /// Write them back as the symbolic links they were, and report them in ``warnings``.
        case keep
        /// Write each as a regular file containing its target text.
        case storeAsFiles
        /// Leave them out.
        case remove
    }

    private struct Item {
        var path: String
        var kind: MDZipEntryKind
        var data: Data
        var compress: Bool
    }

    private var items: [Item]
    private let originalEntryPoint: String?
    private let hadManifest: Bool
    private var manifestFields: MDZipJSONObject?

    /// How to treat symbolic link entries. Default ``SymlinkPolicy/keep``.
    public var symlinkPolicy: SymlinkPolicy = .keep
    /// Set `modified.when` when something changed. Default `true`.
    public var updatesModifiedTimestamp = true
    /// Add a `manifest.json` to an archive that has none. Default `true`.
    public var addsManifestIfMissing = true
    /// The time written to `modified.when` and the ZIP entries. Default: now.
    public var date = Date()
    /// Whether anything has been changed.
    public private(set) var isModified = false
    /// Things the caller should tell the user, such as preserved symbolic links.
    public private(set) var warnings: [String] = []

    /// The manifest members as they will be written, or `nil` if there is no manifest.
    public var manifest: MDZipJSONObject? { manifestFields }

    /// Loads every entry of `archive` (subject to its limits).
    public init(archive: MDZipArchive) throws {
        hadManifest = archive.hasManifest
        originalEntryPoint = try? archive.entryPoint()
        if hadManifest {
            manifestFields = try archive.manifest()?.fields
        }
        var items: [Item] = []
        for r in archive.records {
            let data = r.kind == .directory ? Data() : try ZipReader.read(r, from: archive.source)
            items.append(Item(path: r.name, kind: r.kind, data: data, compress: r.method == 8))
            if r.kind == .symlink || r.kind == .special {
                warnings.append("\"\(r.name)\" is a symbolic link or special entry")
            }
        }
        self.items = items
    }

    // MARK: Entries

    private func fileIndex(_ path: String) -> Int? {
        items.firstIndex { $0.kind == .file && MDZipPath.matches($0.path, path) }
    }

    /// Whether a regular file with this path exists.
    public func contains(_ path: String) -> Bool { fileIndex(path) != nil }

    /// Adds a file, or replaces the one with the same path (an existing file keeps its stored name).
    public mutating func setFile(_ path: String, data: Data) throws {
        let name = MDZipPath.normalized(path)
        if let code = MDZipPath.validate(entryName: name) {
            throw MDZipError(.pathInvalid, "invalid entry name (\(code.rawValue))", path: path, detail: code)
        }
        guard !name.hasSuffix("/") else {
            throw MDZipError(.invalidArgument, "\"\(path)\" ends in / and names a directory", path: path)
        }
        guard !MDZipPath.matches(name, "manifest.json") else {
            throw MDZipError(.invalidArgument, "change manifest.json with updateManifest", path: path)
        }
        if let i = fileIndex(name) {
            items[i].data = data
        } else {
            items.append(Item(path: name, kind: .file, data: data,
                              compress: ZipWriter.shouldCompress(path: name, size: data.count)))
        }
        isModified = true
    }

    /// Adds or replaces UTF-8 text. Markdown gets LF line endings.
    public mutating func setFile(_ path: String, text: String) throws {
        let t = MDZipPath.hasMarkdownExtension(path) ? MDZipMarkdown.normalizeLineEndings(text) : text
        try setFile(path, data: Data(t.utf8))
    }

    /// Removes a file.
    ///
    /// - Throws: `ERR_ENTRY_NOT_FOUND` if there is no such file.
    public mutating func removeFile(_ path: String) throws {
        guard !MDZipPath.matches(path, "manifest.json") else {
            throw MDZipError(.invalidArgument, "manifest.json cannot be removed", path: path)
        }
        guard let i = fileIndex(path) else {
            throw MDZipError(.entryNotFound, "no file named \"\(path)\"", path: path)
        }
        items.remove(at: i)
        isModified = true
    }

    // MARK: Metadata

    /// Changes the manifest members. Members you do not touch, known or not, are kept.
    /// If the archive has no manifest, `body` starts from an empty one.
    public mutating func updateManifest(_ body: (inout MDZipJSONObject) throws -> Void) rethrows {
        var fields = manifestFields ?? MDZipJSONObject()
        try body(&fields)
        manifestFields = fields
        isModified = true
    }

    /// Sets the entry point, which must be a Markdown file in the archive.
    public mutating func setEntryPoint(_ path: String) throws {
        guard let valid = MDZipPath.validEntryPoint(path) else {
            throw MDZipError(.entryPointInvalid, "\"\(path)\" is not a valid entry point path", path: path)
        }
        let stored = try EntryPoint.resolve(files: items.filter { $0.kind == .file }.map { $0.path }, declared: valid)
        updateManifest { $0["entryPoint"] = .string(stored) }
    }

    // MARK: Writing

    /// The edited archive as bytes.
    ///
    /// - Throws: for example `ERR_ENTRYPOINT_MISSING` if the entry point's file was removed,
    ///   `ERR_DUPLICATE_PATH` / `ERR_PATH_CONFLICT`, or `ERR_MANIFEST_INVALID` if the manifest edit
    ///   would make a critical field invalid.
    public func serialize() throws -> Data {
        var entries = items

        // Symbolic links.
        entries = try entries.compactMap { item -> Item? in
            switch (item.kind, symlinkPolicy) {
            case (.symlink, .keep), (.file, _), (.directory, _): return item
            case (.symlink, .storeAsFiles):
                var copy = item
                copy.kind = .file
                return copy
            case (.special, .storeAsFiles):
                var copy = item
                copy.kind = .file
                return copy
            case (_, .remove): return nil
            case (.special, .keep):
                throw MDZipError(.specialEntry,
                                 "\"\(item.path)\" is a special entry that cannot be written back; set symlinkPolicy to .remove or .storeAsFiles",
                                 path: item.path)
            }
        }

        // Manifest.
        let filePaths = entries.filter { $0.kind == .file && !MDZipPath.matches($0.path, "manifest.json") }.map { $0.path }
        var fields = manifestFields
        if fields == nil && addsManifestIfMissing {
            if let original = originalEntryPoint {
                var spec = MDZipJSONObject()
                spec["name"] = "mdzip-spec"
                spec["version"] = .string(MDZipCore.specVersion)
                var producer = MDZipJSONObject()
                producer["core"] = Assembler.producerCore()
                var f = MDZipJSONObject()
                f["spec"] = .object(spec)
                f["producer"] = .object(producer)
                f["mode"] = .string(MDZipMode.document.rawValue)
                f["entryPoint"] = .string(original)
                fields = f
            }
            // With no unambiguous entry point there is nothing correct to declare, so no manifest is added.
        }
        if var f = fields {
            if let ep = f["entryPoint"] {
                // A declared entry point must still resolve: removing its file is rejected. A malformed
                // value is left for the manifest check below to reject.
                if case .string(let declared) = ep, let valid = MDZipPath.validEntryPoint(declared) {
                    _ = try EntryPoint.resolve(files: filePaths, declared: valid)
                }
            } else if let original = originalEntryPoint {
                let now = try? EntryPoint.resolve(files: filePaths, declared: nil)
                if now == nil || !MDZipPath.matches(now!, original) {
                    guard filePaths.contains(where: { MDZipPath.matches($0, original) }) else {
                        throw MDZipError(.entryPointMissing,
                                         "the entry point \"\(original)\" was removed; set a new one with setEntryPoint",
                                         path: original)
                    }
                    f["entryPoint"] = .string(original)
                }
            }
            if isModified && updatesModifiedTimestamp {
                var modified = f["modified"]?.objectValue ?? MDZipJSONObject()
                modified["when"] = .string(MDZipTimestamp.string(date))
                f["modified"] = .object(modified)
            }
            fields = f
        }

        var out: [ZipWriteEntry] = []
        var manifestPlaced = false
        func manifestEntry() throws -> ZipWriteEntry? {
            guard let f = fields else { return nil }
            let data = MDZipManifest(fields: f).serialized()
            _ = try MDZipManifest.parse(data) // never write a manifest that readers would reject
            return ZipWriteEntry(path: "manifest.json", kind: .file, data: data, compress: true)
        }
        for item in entries {
            if item.kind == .file && MDZipPath.matches(item.path, "manifest.json") {
                if let m = try manifestEntry() { out.append(m) }
                manifestPlaced = true
            } else {
                out.append(ZipWriteEntry(path: item.path, kind: item.kind, data: item.data, compress: item.compress))
            }
        }
        if !manifestPlaced, let m = try manifestEntry() { out.insert(m, at: 0) }
        return try Assembler.assemble(out, date: date)
    }

    /// Writes the edited archive to `url`, replacing the file atomically. If anything fails, the
    /// existing file is left as it was.
    public func save(to url: URL) throws {
        try MDZipFile.writeAtomically(try serialize(), to: url)
    }
}

extension MDZipArchive {
    /// Starts an edit of this archive (R6).
    public func editor() throws -> MDZipEditor {
        try MDZipEditor(archive: self)
    }

    /// Applies `changes` and returns the new archive bytes. This archive is not changed.
    public func updated(_ changes: (inout MDZipEditor) throws -> Void) throws -> Data {
        var editor = try MDZipEditor(archive: self)
        try changes(&editor)
        return try editor.serialize()
    }
}
