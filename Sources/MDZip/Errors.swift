import Foundation

/// Stable, machine-readable error codes.
///
/// The raw value of each case is the code string from the MDZip specification
/// (Section 16.5, plus the finer path codes used by the shared fixtures). Compare
/// `MDZipError.code` with a case instead of parsing `MDZipError.message`.
///
/// Codes that start with `ERR_` and are not in the specification are specific to this
/// library; they are marked below.
public enum MDZipErrorCode: String, Sendable, CaseIterable {
    /// Not a valid ZIP container, or uses a compression method other than 0 or 8, or the
    /// entry data is damaged.
    case zipInvalid = "ERR_ZIP_INVALID"
    /// The archive or an entry is encrypted.
    case zipEncrypted = "ERR_ZIP_ENCRYPTED"
    /// An entry name violates Section 5.4. `MDZipError.detail` holds the specific code.
    case pathInvalid = "ERR_PATH_INVALID"
    /// An entry name begins with `/`.
    case pathLeadingSlash = "ERR_PATH_LEADING_SLASH"
    /// An entry name contains a `..` segment.
    case pathTraversal = "ERR_PATH_TRAVERSAL"
    /// An entry name contains a reserved character (`\ : * ? " < > |`).
    case pathReservedChar = "ERR_PATH_RESERVED_CHAR"
    /// An entry name contains a null byte or ASCII control character.
    case pathControlChar = "ERR_PATH_CONTROL_CHAR"
    /// `manifest.json` is unreadable or a critical field has the wrong type or value.
    case manifestInvalid = "ERR_MANIFEST_INVALID"
    /// No unambiguous primary Markdown file can be determined.
    case entryPointUnresolved = "ERR_ENTRYPOINT_UNRESOLVED"
    /// `entryPoint` is not a valid entry point path.
    case entryPointInvalid = "ERR_ENTRYPOINT_INVALID"
    /// `entryPoint` is valid but names no file in the archive.
    case entryPointMissing = "ERR_ENTRYPOINT_MISSING"
    /// `spec.version` has a major version this library does not support.
    case versionUnsupported = "ERR_VERSION_UNSUPPORTED"
    /// A file's path is also the directory of another entry.
    case pathConflict = "ERR_PATH_CONFLICT"
    /// Two entries have equal paths after NFC normalization.
    case duplicatePath = "ERR_DUPLICATE_PATH"
    /// `mode` is a value this library does not recognize.
    case modeUnsupported = "ERR_MODE_UNSUPPORTED"
    /// An entry count, size or compression-ratio limit was exceeded (declared or actual).
    case limitExceeded = "ERR_LIMIT_EXCEEDED"

    /// Library-specific: no file entry with that path.
    case entryNotFound = "ERR_ENTRY_NOT_FOUND"
    /// Library-specific: the entry is not valid UTF-8 text.
    case textDecoding = "ERR_TEXT_DECODING"
    /// Library-specific: a symbolic link or other special entry, which the library never reads as a file.
    case specialEntry = "ERR_SPECIAL_ENTRY"
    /// Library-specific: a caller argument is not acceptable (for example, adding `manifest.json` as a file).
    case invalidArgument = "ERR_INVALID_ARGUMENT"
    /// Library-specific: reading or writing a file on disk failed.
    case io = "ERR_IO"
}

/// An error from the MDZip library. Check `code`; `message` is for people.
public struct MDZipError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// The stable code.
    public let code: MDZipErrorCode
    /// A human-readable explanation. Not stable; do not parse it.
    public let message: String
    /// The archive path the error is about, when there is one.
    public let path: String?
    /// A more specific code, for example the `ERR_PATH_*` code behind `.pathInvalid`.
    public let detail: MDZipErrorCode?

    public init(_ code: MDZipErrorCode, _ message: String, path: String? = nil, detail: MDZipErrorCode? = nil) {
        self.code = code
        self.message = message
        self.path = path
        self.detail = detail
    }

    public var description: String { "\(code.rawValue): \(message)" }
    public var errorDescription: String? { description }
}
