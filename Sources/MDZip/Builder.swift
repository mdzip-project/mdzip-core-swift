import Foundation

/// Creates a new `.mdz` archive (R5).
///
/// ```swift
/// var builder = MDZipBuilder()
/// builder.title = "My Guide"
/// try builder.addFile("index.md", text: "# My Guide\n")
/// try builder.addFile("images/logo.png", data: pngBytes)
/// let bytes = try builder.build()
/// ```
///
/// Every archive gets a `manifest.json` with `spec.version`, `entryPoint`, `title`, `mode`,
/// `producer.core` and `created` (Section 14.1). Entry paths are written in NFC. Files are
/// DEFLATE-compressed when that is likely to help and stored otherwise; no other method is
/// written, and ZIP64 records only if a value needs them.
public struct MDZipBuilder {
    private struct Item {
        var path: String
        var kind: MDZipEntryKind
        var data: Data
    }
    private var items: [Item] = []

    /// The document title. Defaults to the entry point's first `# ` heading, then its file name.
    public var title: String?
    /// The archive mode. Default `document`.
    public var mode: MDZipMode = .document
    /// The entry point path. If `nil`, it is found by the rules of Section 5.5 among the added files.
    public var entryPoint: String?
    /// Extra manifest fields, written as given: `author`, `description`, `license`, `keywords`,
    /// `cover`, `producer.application`, unknown `x-` fields, and so on. The library sets
    /// `spec`, `mode`, `entryPoint` and `producer.core`; sub-fields you supply inside `spec` and
    /// `producer` are kept.
    public var metadata = MDZipJSONObject()
    /// Convert CRLF to LF in Markdown added with ``addFile(_:text:)`` (Section 12.2). Default `true`.
    /// Bytes added with ``addFile(_:data:)`` are never changed.
    public var normalizesLineEndings = true
    /// The time written to `created.when` and the ZIP entries. Default: now.
    public var date: Date = Date()

    public init() {}

    /// Records the application producing the archive in `producer.application` (Section 6.2).
    public mutating func setApplication(name: String, version: String, url: String? = nil) {
        var app = MDZipJSONObject()
        app["name"] = .string(name)
        app["version"] = .string(version)
        if let url = url { app["url"] = .string(url) }
        var producer = metadata["producer"]?.objectValue ?? MDZipJSONObject()
        producer["application"] = .object(app)
        metadata["producer"] = .object(producer)
    }

    private static func normalizedName(_ path: String) throws -> String {
        let name = MDZipPath.normalized(path)
        if let code = MDZipPath.validate(entryName: name) {
            throw MDZipError(.pathInvalid, "invalid entry name (\(code.rawValue))", path: path, detail: code)
        }
        return name
    }

    /// Adds a file, or replaces the file with the same path. `manifest.json` is written by the
    /// library; set ``metadata`` instead.
    ///
    /// - Throws: `ERR_PATH_INVALID` (with a specific `detail`) if the path breaks Section 5.4.
    public mutating func addFile(_ path: String, data: Data) throws {
        let name = try MDZipBuilder.normalizedName(path)
        guard !name.hasSuffix("/") else {
            throw MDZipError(.invalidArgument, "\"\(path)\" ends in / and is a directory; use addDirectory", path: path)
        }
        guard name != "manifest.json" else {
            throw MDZipError(.invalidArgument, "manifest.json is written by the library; set metadata instead", path: path)
        }
        if let i = items.firstIndex(where: { $0.kind == .file && MDZipPath.matches($0.path, name) }) {
            items[i].data = data
        } else {
            items.append(Item(path: name, kind: .file, data: data))
        }
    }

    /// Adds UTF-8 text. Markdown files get LF line endings if ``normalizesLineEndings`` is set.
    public mutating func addFile(_ path: String, text: String) throws {
        var text = text
        if normalizesLineEndings && MDZipPath.hasMarkdownExtension(path) {
            text = MDZipMarkdown.normalizeLineEndings(text)
        }
        try addFile(path, data: Data(text.utf8))
    }

    /// Adds an empty directory entry. Directory entries are optional; they are only needed to keep an empty folder.
    public mutating func addDirectory(_ path: String) throws {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = try MDZipBuilder.normalizedName(trimmed) + "/"
        if !items.contains(where: { $0.kind == .directory && MDZipPath.matches($0.path, name) }) {
            items.append(Item(path: name, kind: .directory, data: Data()))
        }
    }

    /// Builds the archive.
    ///
    /// - Throws: `ERR_DUPLICATE_PATH` / `ERR_PATH_CONFLICT` for clashing names;
    ///   `ERR_ENTRYPOINT_INVALID`, `ERR_ENTRYPOINT_MISSING` or `ERR_ENTRYPOINT_UNRESOLVED` if the entry
    ///   point cannot be set; `ERR_MANIFEST_INVALID` (and its siblings) if ``metadata`` would write a
    ///   manifest that consumers would reject or ignore.
    public func build() throws -> Data {
        let files = items.filter { $0.kind == .file }
        let paths = files.map { $0.path }

        // Entry point.
        let entry: String
        if let requested = entryPoint {
            guard let valid = MDZipPath.validEntryPoint(requested) else {
                throw MDZipError(.entryPointInvalid, "\"\(requested)\" is not a valid entry point path", path: requested)
            }
            entry = try EntryPoint.resolve(files: paths, declared: valid)
        } else {
            entry = try EntryPoint.resolve(files: paths, declared: nil)
        }

        // Title.
        var documentTitle = title ?? metadata["title"]?.stringValue
        if documentTitle == nil, let item = files.first(where: { $0.path == entry }),
           let text = MDZipText.decode(item.data) {
            documentTitle = MDZipMarkdown.firstHeading(text)
        }
        if documentTitle == nil {
            let name = entry.split(separator: "/").last.map(String.init) ?? entry
            documentTitle = name.split(separator: ".").first.map(String.init) ?? name
        }

        // Manifest: spec, producer, title, mode, entryPoint, created, then everything else.
        var spec = metadata["spec"]?.objectValue ?? MDZipJSONObject()
        spec["name"] = "mdzip-spec"
        spec["version"] = .string(MDZipCore.specVersion)
        var producer = metadata["producer"]?.objectValue ?? MDZipJSONObject()
        producer["core"] = Assembler.producerCore()

        var fields = MDZipJSONObject()
        fields["spec"] = .object(spec)
        fields["producer"] = .object(producer)
        fields["title"] = .string(documentTitle ?? entry)
        fields["mode"] = .string(mode.rawValue)
        fields["entryPoint"] = .string(entry)
        if let created = metadata["created"] {
            fields["created"] = created
        } else {
            var created = MDZipJSONObject()
            created["when"] = .string(MDZipTimestamp.string(date))
            fields["created"] = .object(created)
        }
        for (key, value) in metadata.members where fields[key] == nil { fields[key] = value }

        // Refuse a manifest that consumers would reject or quietly ignore parts of.
        let manifest = MDZipManifest(fields: fields)
        let text = manifest.serialized()
        let checked = try MDZipManifest.parse(text)
        if let bad = checked.ignoredFields.first {
            throw MDZipError(.manifestInvalid, "the manifest field \"\(bad)\" has a wrong type or value and would be ignored by readers",
                             path: "manifest.json")
        }

        var out = [ZipWriteEntry(path: "manifest.json", kind: .file, data: text, compress: true)]
        for item in items {
            out.append(ZipWriteEntry(path: item.path, kind: item.kind, data: item.data,
                                     compress: ZipWriter.shouldCompress(path: item.path, size: item.data.count)))
        }
        return try Assembler.assemble(out, date: date)
    }

    /// Builds the archive and writes it to `url`. The file is replaced atomically: if building or
    /// writing fails, an existing file at `url` is left as it was.
    public func write(to url: URL) throws {
        try MDZipFile.writeAtomically(try build(), to: url)
    }
}

enum MDZipFile {
    static func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw MDZipError(.io, "cannot write \(url.path): \(error.localizedDescription)")
        }
    }
}
