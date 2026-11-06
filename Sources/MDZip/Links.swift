import Foundation

/// Why a link could not be resolved.
public enum MDZipUnresolvedReason: String, Sendable {
    /// The destination is not a valid relative link (leading `/`, a backslash, bad percent-encoding,
    /// an encoded separator).
    case invalid
    /// No file with that path is in the archive (including a case-only difference).
    case notFound
    /// The link leaves the archive, or enters another one. This library has no host
    /// filesystem, so such links are unresolved (Sections 9.4 and 9.5 are optional).
    case unsupported
    /// The link ends in `/`, so it names a directory, and entries are files.
    case directory
    /// The path is a symbolic link entry, which is never followed.
    case symbolicLink
}

/// The outcome of resolving a link destination (Section 9.3).
public enum MDZipLinkResolution: Sendable, Equatable {
    /// A file in the archive. `entry` is its stored path. `fragment` is the text after `#`, as
    /// written (not decoded), or `nil`.
    case internalEntry(entry: String, fragment: String?)
    /// An external URL (it has a scheme such as `https:` or `mailto:`). It is returned as written
    /// and never loaded.
    case external(url: String)
    /// No target. The library never substitutes a different one.
    case unresolved(MDZipUnresolvedReason)
}

extension MDZipArchive {
    /// Resolves a link destination found in a document of this archive (R3).
    ///
    /// Follows Section 9.3: the fragment and query are split off, a leading `/` or a backslash is
    /// invalid, each segment is percent-decoded once as UTF-8, `.` and empty segments stay in place,
    /// and `..` climbs. The result is matched case-sensitively after NFC normalization.
    ///
    /// Links outside the archive (a `..` above the root) and into other archives need a host
    /// filesystem and are optional; they are `unresolved(.unsupported)`, never clamped at the
    /// root and never mapped to a file inside the archive. Symbolic link entries are never
    /// matched.
    ///
    /// - Parameters:
    ///   - destination: the link destination as written in the Markdown or HTML.
    ///   - sourcePath: the archive path of the document containing the link.
    public func resolveLink(_ destination: String, from sourcePath: String) -> MDZipLinkResolution {
        // 1. Fragment, then query.
        var rest = Substring(destination)
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            let f = String(rest[rest.index(after: hash)...])
            fragment = f.isEmpty ? nil : f
            rest = rest[..<hash]
        }
        if let q = rest.firstIndex(of: "?") { rest = rest[..<q] }
        let path = String(rest)

        // A destination with a scheme is an external URL, not a path.
        if MDZipArchive.hasScheme(path) { return .external(url: destination) }

        // 2. Nothing left: the link refers to the document itself.
        if path.isEmpty {
            guard let source = record(at: sourcePath) else { return .unresolved(.notFound) }
            return .internalEntry(entry: source.name, fragment: fragment)
        }
        // 3. Not a valid relative link.
        if path.unicodeScalars.first == "/" || path.unicodeScalars.contains("\\") { return .unresolved(.invalid) }

        // 4. Segments, percent-decoded once.
        var segments: [String] = []
        for raw in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = MDZipArchive.percentDecode(String(raw)) else { return .unresolved(.invalid) }
            if decoded.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) {
                return .unresolved(.invalid)
            }
            segments.append(decoded)
        }

        // 5. Walk from the directory of the source document.
        var stack = MDZipPath.segments(sourcePath)
        stack.removeLast()
        for segment in segments {
            if segment.isEmpty || segment == "." { continue }
            if segment == ".." {
                if stack.isEmpty { return .unresolved(.unsupported) } // leaves the archive; never clamped
                stack.removeLast()
            } else {
                stack.append(segment)
            }
        }
        if path.hasSuffix("/") { return .unresolved(.directory) }

        // 6. Match.
        let target = stack.joined(separator: "/")
        if let r = record(at: target) { return .internalEntry(entry: r.name, fragment: fragment) }
        let key = MDZipPath.normalized(target)
        if records.contains(where: { $0.kind == .symlink && MDZipPath.normalized($0.name) == key }) {
            return .unresolved(.symbolicLink)
        }
        return .unresolved(.notFound)
    }

    /// `scheme:` per RFC 3986: a letter, then letters, digits, `+`, `-` or `.`, then `:`.
    private static func hasScheme(_ s: String) -> Bool {
        var scalars = s.unicodeScalars.makeIterator()
        guard let first = scalars.next(), first.isASCII, first.properties.isAlphabetic else { return false }
        while let c = scalars.next() {
            if c == ":" { return true }
            let ok = c.isASCII && (c.properties.isAlphabetic || (c.value >= 0x30 && c.value <= 0x39)
                                   || c == "+" || c == "-" || c == ".")
            if !ok { return false }
        }
        return false
    }

    /// Decodes `%XX` sequences as UTF-8, once. Returns `nil` for invalid encoding.
    private static func percentDecode(_ s: String) -> String? {
        guard s.utf8.contains(UInt8(ascii: "%")) else { return s }
        var out = [UInt8]()
        let bytes = Array(s.utf8)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%") {
                guard i + 2 < bytes.count,
                      let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) else { return nil }
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return MDZipText.decode(Data(out))
    }
}
