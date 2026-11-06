import Foundation

/// One validation finding.
public struct MDZipFinding: Sendable, Equatable {
    public enum Severity: String, Sendable {
        /// The archive does not conform, or cannot be used as it is.
        case error
        /// The archive conforms but something looks wrong, or a SHOULD is not met.
        case warning
        /// Information only, for example that there is no manifest.
        case note
    }

    public let severity: Severity
    /// A stable code. Errors use the `ERR_*` codes of ``MDZipErrorCode``; warnings and notes use
    /// `WARN_*` and `NOTE_*` codes (listed in the README).
    public let code: String
    public let message: String
    /// The archive path the finding is about, when there is one.
    public let path: String?
}

/// The result of ``MDZipArchive/validate()``.
public struct MDZipValidationReport: Sendable {
    public let findings: [MDZipFinding]
    public var errors: [MDZipFinding] { findings.filter { $0.severity == .error } }
    public var warnings: [MDZipFinding] { findings.filter { $0.severity == .warning } }
    public var notes: [MDZipFinding] { findings.filter { $0.severity == .note } }
    /// `true` when there are no errors. Warnings and notes do not make an archive non-conforming.
    public var isConforming: Bool { errors.isEmpty }
}

extension MDZipArchive {
    /// Validates archive-level and manifest conformance (R4) and returns every finding.
    ///
    /// Problems that stop an archive from opening at all (a damaged ZIP, bad entry names, exceeded
    /// limits) are reported by the throwing initializers; use ``validate(data:limits:)`` to get those as findings too.
    public func validate() -> MDZipValidationReport {
        var findings: [MDZipFinding] = []
        func add(_ severity: MDZipFinding.Severity, _ code: String, _ message: String, _ path: String? = nil) {
            findings.append(MDZipFinding(severity: severity, code: code, message: message, path: path))
        }
        func add(error: MDZipError) {
            add(.error, error.code.rawValue, error.message, error.path)
        }

        // Entries.
        for r in records {
            if r.kind == .symlink || r.kind == .special {
                add(.warning, "WARN_SYMLINK_ENTRY",
                    "\"\(r.name)\" is a symbolic link or special entry; it is never followed and a conforming producer does not write one",
                    r.name)
            }
            if !r.name.unicodeScalars.allSatisfy({ $0.isASCII }) {
                if !r.usesUTF8Flag {
                    add(.warning, "WARN_UTF8_FLAG_MISSING", "the name has non-ASCII characters but the UTF-8 flag is not set", r.name)
                }
                if !MDZipPath.normalized(r.name).unicodeScalars.elementsEqual(r.name.unicodeScalars) {
                    add(.warning, "WARN_PATH_NOT_NFC", "the name is not in Unicode Normalization Form C", r.name)
                }
            }
        }
        var folded: [String: String] = [:]
        for r in records {
            let key = MDZipPath.normalized(r.name).lowercased()
            if let other = folded[key] {
                add(.warning, "WARN_CASE_COLLISION",
                    "\"\(r.name)\" and \"\(other)\" differ only in case and collide on a case-insensitive filesystem", r.name)
            } else {
                folded[key] = r.name
            }
        }

        // Manifest.
        var manifest: MDZipManifest?
        var manifestFailed = false
        if hasManifest {
            do {
                let m = try self.manifest()!
                manifest = m
                for field in m.ignoredFields {
                    add(.warning, "WARN_FIELD_IGNORED", "the manifest field \"\(field)\" has a wrong type or value and is ignored", "manifest.json")
                }
                for pointer in m.duplicateMembers {
                    add(.warning, "WARN_DUPLICATE_MEMBER", "the manifest has more than one member at \(pointer); the last is used", "manifest.json")
                }
                for note in m.warnings {
                    add(.warning, "WARN_SPEC_VERSION_OLDER", note, "manifest.json")
                }
                if m.specVersion == nil {
                    add(.note, "NOTE_NO_SPEC_VERSION", "the manifest has no spec.version; treated as baseline 1.x", "manifest.json")
                }
                if let cover = m.cover, !contains(cover) {
                    var message = "the cover \"\(cover)\" is not in the archive and is ignored"
                    if let near = nearMatch(for: cover) { message += "; did you mean \"\(near)\"?" }
                    add(.warning, "WARN_COVER_MISSING", message, "manifest.json")
                }
            } catch let e as MDZipError {
                manifestFailed = true
                add(error: e)
            } catch {
                manifestFailed = true
                add(.error, MDZipErrorCode.manifestInvalid.rawValue, "\(error)", "manifest.json")
            }
        } else {
            add(.note, "NOTE_NO_MANIFEST", "there is no manifest.json; defaults and entry point discovery apply (Section 5.5)")
        }

        // Entry point.
        if !manifestFailed {
            do {
                _ = try EntryPoint.resolve(files: files.map { $0.path }, declared: manifest?.entryPoint)
            } catch let e as MDZipError {
                var message = e.message
                if e.code == .entryPointMissing, let ep = manifest?.entryPoint, let near = nearMatch(for: ep) {
                    message += "; did you mean \"\(near)\"?"
                }
                add(.error, e.code.rawValue, message, e.path)
            } catch {
                add(.error, MDZipErrorCode.entryPointUnresolved.rawValue, "\(error)")
            }
        }
        return MDZipValidationReport(findings: findings)
    }

    /// Validates archive bytes without throwing. If the archive cannot be opened, the report has
    /// one error finding with the error's code (and, for bad entry names, the specific
    /// `ERR_PATH_*` code as its message prefix).
    public static func validate(data: Data, limits: MDZipLimits = .default) -> MDZipValidationReport {
        do {
            return try MDZipArchive(data: data, limits: limits).validate()
        } catch let e as MDZipError {
            var message = e.message
            if let detail = e.detail { message = "\(detail.rawValue): \(message)" }
            return MDZipValidationReport(findings: [MDZipFinding(severity: .error, code: e.code.rawValue,
                                                                 message: message, path: e.path)])
        } catch {
            return MDZipValidationReport(findings: [MDZipFinding(severity: .error, code: MDZipErrorCode.zipInvalid.rawValue,
                                                                 message: "\(error)", path: nil)])
        }
    }
}
