import Foundation

/// The interpretation mode of an archive (Section 5.7).
public enum MDZipMode: String, Sendable {
    /// One logical publication. The default when no mode is declared.
    case document
    /// A collection of independent documents.
    case project
}

/// A parsed and validated `manifest.json` (Section 6).
///
/// The manifest keeps every member it was read with, including ones this library does not
/// know, in `fields`. Editing goes through `fields`, so unknown data survives a rewrite.
public struct MDZipManifest: Sendable {
    /// The highest `spec.version` major version this library supports.
    public static let supportedMajorVersion = 1

    /// All members, in their original order, with duplicate member names resolved (the last
    /// value wins, as Section 6.4 requires).
    public var fields: MDZipJSONObject

    /// Descriptive top-level fields that had a wrong type or value and are ignored
    /// (for example `title` when it is a number). The archive still opens (Section 6.4).
    public internal(set) var ignoredFields: [String]
    /// JSON Pointers of members that appeared more than once (Section 6.4).
    public internal(set) var duplicateMembers: [String]
    /// Informational notes, such as an older `spec.version` major version.
    public internal(set) var warnings: [String]

    public init(fields: MDZipJSONObject = MDZipJSONObject()) {
        self.fields = fields
        ignoredFields = []
        duplicateMembers = []
        warnings = []
    }

    // MARK: Parsing and validation

    /// Parses and validates the text of a `manifest.json`.
    ///
    /// - Throws: `ERR_MANIFEST_INVALID` for unreadable manifests and critical fields with
    ///   the wrong type (`spec`, `spec.version`, a non-string `mode`);
    ///   `ERR_VERSION_UNSUPPORTED` for a newer major version; `ERR_MODE_UNSUPPORTED` for an
    ///   unrecognized `mode`; `ERR_ENTRYPOINT_INVALID` for a malformed `entryPoint`.
    public static func parse(_ data: Data) throws -> MDZipManifest {
        guard let text = MDZipText.decode(data) else {
            throw MDZipError(.manifestInvalid, "manifest.json is not valid UTF-8", path: "manifest.json")
        }
        return try parse(bytes: Array(text.utf8))
    }

    /// Parses and validates the text of a `manifest.json`. 
    public static func parse(_ text: String) throws -> MDZipManifest {
        try parse(bytes: Array(text.utf8))
    }

    private static func parse(bytes: [UInt8]) throws -> MDZipManifest {
        var parser = JSONParser(bytes: bytes)
        let root: MDZipJSON
        do {
            root = try parser.parse()
        } catch let e as JSONSyntaxError {
            throw MDZipError(.manifestInvalid, "manifest.json is not valid JSON: \(e.message)", path: "manifest.json")
        }
        guard case .object(let object) = root else {
            throw MDZipError(.manifestInvalid, "the top-level value of manifest.json is not an object",
                             path: "manifest.json")
        }
        var manifest = MDZipManifest(fields: object)
        manifest.duplicateMembers = parser.duplicates
        try manifest.validateCriticalFields()
        manifest.validateDescriptiveFields()
        return manifest
    }

    private mutating func validateCriticalFields() throws {
        // spec and spec.version
        if let spec = fields["spec"] {
            guard case .object(let specObject) = spec else {
                throw MDZipError(.manifestInvalid, "\"spec\" is not an object", path: "manifest.json")
            }
            if let version = specObject["version"] {
                guard case .string(let v) = version, let parts = MDZipManifest.semanticVersion(v) else {
                    throw MDZipError(.manifestInvalid, "\"spec.version\" is not a Semantic Versioning 2.0.0 string",
                                     path: "manifest.json")
                }
                if parts.major > MDZipManifest.supportedMajorVersion {
                    throw MDZipError(.versionUnsupported,
                                     "spec.version \(v) is newer than the supported major version \(MDZipManifest.supportedMajorVersion)",
                                     path: "manifest.json")
                }
                if parts.major < MDZipManifest.supportedMajorVersion {
                    warnings.append("spec.version \(v) is older than the supported major version \(MDZipManifest.supportedMajorVersion)")
                }
            }
        }
        // mode
        if let mode = fields["mode"] {
            guard case .string(let m) = mode else {
                throw MDZipError(.manifestInvalid, "\"mode\" is not a string", path: "manifest.json")
            }
            if MDZipMode(rawValue: m) == nil {
                throw MDZipError(.modeUnsupported, "unrecognized mode \"\(m)\"", path: "manifest.json")
            }
        }
        // entryPoint
        if let ep = fields["entryPoint"] {
            guard case .string(let s) = ep, MDZipPath.validEntryPoint(s) != nil else {
                throw MDZipError(.entryPointInvalid, "\"entryPoint\" is not a valid entry point path",
                                 path: "manifest.json")
            }
        }
    }

    private mutating func validateDescriptiveFields() {
        func isString(_ v: MDZipJSON?) -> Bool { if case .string = v { return true } else { return false } }
        func isNonEmptyString(_ v: MDZipJSON?) -> Bool { if case .string(let s) = v { return !s.isEmpty } else { return false } }
        /// An object whose listed members, when present, are strings.
        func stringMembers(_ v: MDZipJSON?, _ names: [String]) -> Bool {
            guard case .object(let o) = v else { return false }
            return names.allSatisfy { o[$0] == nil || isString(o[$0]) }
        }
        func person(_ v: MDZipJSON?) -> Bool { stringMembers(v, ["name", "email", "url"]) }
        func party(_ v: MDZipJSON?, _ name: String) -> Bool {
            guard case .object(let o) = v else { return false }
            return stringMembers(o[name], ["name", "version", "url"]) || o[name] == nil
        }
        func timestamp(_ v: MDZipJSON?) -> Bool {
            switch v {
            case .string(let s)?: return MDZipManifest.isRFC3339(s)
            case .object(let o)?:
                guard case .string(let when)? = o["when"], MDZipManifest.isRFC3339(when) else { return false }
                return o["by"] == nil || person(o["by"])
            default: return false
            }
        }

        var ignored: [String] = []
        for (key, value) in fields.members {
            let ok: Bool
            switch key {
            case "title": ok = isNonEmptyString(value)
            case "language", "description", "version", "license": ok = isString(value)
            case "author": ok = person(value)
            case "producer":
                if case .object(let o) = value {
                    ok = (o["application"] == nil || party(value, "application"))
                        && (o["core"] == nil || party(value, "core"))
                } else {
                    ok = false
                }
            case "created", "modified": ok = timestamp(value)
            case "keywords":
                if case .array(let a) = value { ok = a.allSatisfy { isString($0) } } else { ok = false }
            case "cover":
                if case .string(let s) = value { ok = MDZipPath.validFilePath(s) != nil } else { ok = false }
            default: ok = true // critical fields were checked; unknown fields are never validated
            }
            if !ok { ignored.append(key) }
        }
        ignoredFields = ignored
    }

    // MARK: Typed access (ignored fields read as nil)

    private func descriptiveString(_ key: String) -> String? {
        guard !ignoredFields.contains(key), case .string(let s)? = fields[key] else { return nil }
        return s
    }

    /// `spec.version`, if declared.
    public var specVersion: String? {
        guard case .object(let spec)? = fields["spec"], case .string(let v)? = spec["version"] else { return nil }
        return v
    }
    /// The effective mode: the declared one, or `document` when none is declared.
    public var mode: MDZipMode {
        if case .string(let m)? = fields["mode"], let mode = MDZipMode(rawValue: m) { return mode }
        return .document
    }
    /// The declared `entryPoint` with a leading `./` removed, if there is one. Always a
    /// valid entry point path (parsing rejects others).
    public var entryPoint: String? {
        guard case .string(let s)? = fields["entryPoint"] else { return nil }
        return MDZipPath.validEntryPoint(s)
    }
    public var title: String? { descriptiveString("title") }
    public var language: String? { descriptiveString("language") }
    public var summary: String? { descriptiveString("description") }
    public var documentVersion: String? { descriptiveString("version") }
    public var license: String? { descriptiveString("license") }
    /// The declared `cover` path with a leading `./` removed, if it is valid.
    public var cover: String? { descriptiveString("cover").flatMap(MDZipPath.validFilePath) }
    public var keywords: [String]? {
        guard !ignoredFields.contains("keywords"), case .array(let a)? = fields["keywords"] else { return nil }
        return a.compactMap { $0.stringValue }
    }

    // MARK: Helpers

    /// Semantic Versioning 2.0.0 (https://semver.org). Returns the major, minor and patch numbers.
    static func semanticVersion(_ s: String) -> (major: Int, minor: Int, patch: Int)? {
        let pattern = "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)"
            + "(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?"
            + "(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: s, range: range), m.range == range else { return nil }
        func part(_ i: Int) -> Int? { Int(ns.substring(with: m.range(at: i))) }
        guard let major = part(1), let minor = part(2), let patch = part(3) else { return nil }
        return (major, minor, patch)
    }

    /// RFC 3339 `date-time`, for example `2026-03-08T14:30:00Z` or `2026-03-08T09:30:00-05:00`.
    static func isRFC3339(_ s: String) -> Bool {
        let u = Array(s.utf8)
        func digit(_ i: Int) -> Int? { i < u.count && u[i] >= 0x30 && u[i] <= 0x39 ? Int(u[i] - 0x30) : nil }
        func num(_ start: Int, _ count: Int) -> Int? {
            var v = 0
            for i in start..<(start + count) {
                guard let d = digit(i) else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard u.count >= 20, let year = num(0, 4), u[4] == UInt8(ascii: "-"), let month = num(5, 2),
              u[7] == UInt8(ascii: "-"), let day = num(8, 2),
              u[10] == UInt8(ascii: "T") || u[10] == UInt8(ascii: "t"),
              let hour = num(11, 2), u[13] == UInt8(ascii: ":"), let minute = num(14, 2),
              u[16] == UInt8(ascii: ":"), let second = num(17, 2) else { return false }
        guard (1...12).contains(month), hour < 24, minute < 60, second <= 60 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1, day <= days[month - 1] else { return false }
        var i = 19
        if i < u.count, u[i] == UInt8(ascii: ".") {
            i += 1
            let start = i
            while digit(i) != nil { i += 1 }
            if i == start { return false }
        }
        guard i < u.count else { return false }
        if u[i] == UInt8(ascii: "Z") || u[i] == UInt8(ascii: "z") { return i == u.count - 1 }
        guard u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-"), i + 6 == u.count,
              let oh = num(i + 1, 2), u[i + 3] == UInt8(ascii: ":"), let om = num(i + 4, 2) else { return false }
        return oh < 24 && om < 60
    }

    /// The manifest as JSON text, ready to store as `manifest.json`.
    public func serialized() -> Data {
        Data(MDZipJSON.object(fields).serialized().utf8)
    }
}

/// UTF-8 text decoding that behaves the same on every platform.
enum MDZipText {
    /// Decodes strictly: returns `nil` for invalid UTF-8. A byte order mark is kept.
    static func decode(_ data: Data) -> String? {
        var decoder = UTF8()
        var iterator = data.makeIterator()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
