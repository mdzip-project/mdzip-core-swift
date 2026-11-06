import Foundation

/// Entry-name rules (Section 5.4) and path matching (Section 5.4.1).
public enum MDZipPath {
    /// Normalizes to Unicode Normalization Form C. This is the only normalization applied to
    /// stored paths.
    public static func normalized(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    /// Whether two paths are the same entry: equal after NFC, compared case-sensitively.
    ///
    /// Swift's `String ==` already treats canonically equivalent text as equal and never folds
    /// case; the comparison here is by code point after NFC, as the specification says.
    public static func matches(_ a: String, _ b: String) -> Bool {
        normalized(a).unicodeScalars.elementsEqual(normalized(b).unicodeScalars)
    }

    /// Checks a stored entry name against Section 5.4. Returns `nil` when it is acceptable, or
    /// the specific error code: `.pathLeadingSlash`, `.pathTraversal`, `.pathReservedChar`,
    /// `.pathControlChar` or `.pathInvalid`. A name ending in `/` is a directory entry and is
    /// checked without that slash.
    public static func validate(entryName name: String) -> MDZipErrorCode? {
        if name.isEmpty { return .pathInvalid }
        if name.unicodeScalars.first == "/" { return .pathLeadingSlash }
        for u in name.unicodeScalars {
            if u.value < 0x20 || u.value == 0x7F { return .pathControlChar }
        }
        for u in name.unicodeScalars where reservedCharacters.contains(u) {
            return .pathReservedChar
        }
        var scalars = Array(name.unicodeScalars)
        if scalars.last == "/" { scalars.removeLast() }
        if scalars.isEmpty { return .pathInvalid }
        var traversal = false
        var other = false
        for segment in split(scalars) {
            if segment.count == 2 && segment[0] == "." && segment[1] == "." {
                traversal = true
            } else if segment.isEmpty || (segment.count == 1 && segment[0] == ".") {
                other = true
            }
        }
        if traversal { return .pathTraversal }
        if other { return .pathInvalid }
        return nil
    }

    private static let reservedCharacters: Set<Unicode.Scalar> = ["\\", ":", "*", "?", "\"", "<", ">", "|"]

    private static func split(_ scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var parts: [[Unicode.Scalar]] = [[]]
        for u in scalars {
            if u == "/" { parts.append([]) } else { parts[parts.count - 1].append(u) }
        }
        return parts
    }

    /// Splits a path on `/`, keeping empty segments.
    static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: ASCII-only comparisons (Section 5.4.1): never locale-sensitive.

    static func asciiLowercased(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.value >= 0x41 && u.value <= 0x5A, let l = Unicode.Scalar(u.value + 0x20) {
                out.append(l)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    /// `.md` or `.markdown`, compared ASCII case-insensitively.
    static func hasMarkdownExtension(_ path: String) -> Bool {
        let name = asciiLowercased(path)
        return name.hasSuffix(".md") || name.hasSuffix(".markdown")
    }

    private static let supportNames: Set<String> = ["readme", "agents", "license", "changelog", "contributing"]

    /// A root-level support file: README, AGENTS, LICENSE, CHANGELOG or CONTRIBUTING with a
    /// `.md` or `.markdown` extension (Section 5.5).
    static func isSupportFile(rootLevelName name: String) -> Bool {
        let lower = asciiLowercased(name)
        for ext in [".md", ".markdown"] where lower.hasSuffix(ext) {
            let stem = String(lower.dropLast(ext.count))
            if supportNames.contains(stem) { return true }
        }
        return false
    }

    /// Whether `value` is a valid `entryPoint` path (Section 5.5): non-empty, a relative path
    /// satisfying Section 5.4 after one leading `./` is removed, naming a file, with a Markdown
    /// extension. Returns the path with the `./` removed, or `nil` if it is not valid.
    static func validEntryPoint(_ value: String) -> String? {
        let path = strippingLeadingDotSlash(value)
        guard !path.isEmpty, !path.hasSuffix("/"), validate(entryName: path) == nil,
              hasMarkdownExtension(path) else { return nil }
        return path
    }

    /// A valid `cover` path: like an entry point but with any extension.
    static func validFilePath(_ value: String) -> String? {
        let path = strippingLeadingDotSlash(value)
        guard !path.isEmpty, !path.hasSuffix("/"), validate(entryName: path) == nil else { return nil }
        return path
    }

    static func strippingLeadingDotSlash(_ value: String) -> String {
        value.hasPrefix("./") ? String(value.dropFirst(2)) : value
    }
}
