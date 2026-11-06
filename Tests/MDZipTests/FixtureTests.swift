import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import MDZip

/// The shared specification fixtures (spec v1.2.1), run through the public API.
/// Each test prints a `FIXTURE-RESULT` line that the README table is built from.
final class FixtureConsumerTests: XCTestCase {
    func testT001_minimal() throws {
        let a = try Fixtures.archive("minimal.mdz")
        XCTAssertEqual(try a.entryPoint(), "index.md")
        XCTAssertFalse(try a.text(at: "index.md").isEmpty)
        report("T-001", "passed")
    }

    func testT002_withManifest() throws {
        let a = try Fixtures.archive("with-manifest.mdz")
        let declared = try XCTUnwrap(try a.manifest()?.entryPoint)
        XCTAssertEqual(try a.entryPoint(), declared)
        XCTAssertTrue(a.validate().isConforming)
        report("T-002", "passed")
    }

    func testT003_missingIndexNoReadmeFallback() throws {
        let a = try Fixtures.archive("invalid-missing-index.mdz")
        XCTAssertTrue(a.contains("README.md"))
        XCTAssertCode(try a.entryPoint(), .entryPointMissing)
        report("T-003", "passed")
    }

    func testT004_badEntryPoint() throws {
        let a = try Fixtures.archive("invalid-bad-entrypoint.mdz")
        XCTAssertTrue(a.contains("index.md"))
        XCTAssertCode(try a.entryPoint(), .entryPointMissing)
        report("T-004", "passed")
    }

    func testT005_crlf() throws {
        let a = try Fixtures.archive("line-endings-crlf.mdz")
        let t = try a.text(at: try a.entryPoint())
        XCTAssertTrue(t.contains("\r\n"))
        report("T-005", "passed")
    }

    private func entryPointArchive(_ c: [String: Any]) -> Data {
        var manifest: String?
        if let text = c["manifestJson"] as? String {
            manifest = text
        } else if let m = c["manifest"], !(m is NSNull) {
            manifest = String(data: try! JSONSerialization.data(withJSONObject: m), encoding: .utf8)
        } else if (c["files"] as! [String]).contains("manifest.json") {
            manifest = "{}"
        }
        return RawZip.make(names: c["files"] as! [String], manifest: manifest)
    }

    func testT006_T008_entryPointCases() throws {
        var supportCases = 0, errorCases = 0
        for c in try Fixtures.objects("entrypoint-cases.json") {
            let name = c["name"] as! String
            let a = try MDZipArchive(data: entryPointArchive(c))
            let expectedError = c["expectedError"] as? String
            let expected = c["expectedEntryPoint"] as? String
            if expectedError != nil { errorCases += 1 }
            if name.contains("support") || name.contains("set aside") { supportCases += 1 }
            do {
                let ep = try a.entryPoint()
                XCTAssertNil(expectedError, name)
                XCTAssertNotNil(expected, "\(name): expected no entry point, got \(ep)")
                if let expected = expected { XCTAssertTrue(MDZipPath.matches(ep, expected), "\(name): \(ep)") }
            } catch let e as MDZipError {
                if let expectedError = expectedError {
                    XCTAssertEqual(e.code.rawValue, expectedError, name)
                } else {
                    XCTAssertNil(expected, "\(name): \(e)")
                    XCTAssertEqual(e.code, .entryPointUnresolved, name)
                }
            }
        }
        XCTAssertGreaterThan(supportCases, 5)
        XCTAssertGreaterThan(errorCases, 5)
        report("T-006", "passed", "support-file cases")
        report("T-008", "passed", "invalid vs missing entryPoint")
    }

    func testT007_noManifest() throws {
        let a = try Fixtures.archive("minimal.mdz")
        XCTAssertFalse(a.hasManifest)
        XCTAssertNil(try a.manifest())
        XCTAssertEqual(try a.mode(), .document)
        let r = a.validate()
        XCTAssertTrue(r.isConforming)
        XCTAssertTrue(r.warnings.isEmpty)
        report("T-007", "passed")
    }

    func testT009_pathMatching() throws {
        for c in try Fixtures.objects("path-matching-cases.json") {
            let entry = c["entry"] as! String, lookup = c["lookup"] as! String, matches = c["matches"] as! Bool
            XCTAssertEqual(MDZipPath.matches(entry, lookup), matches, c["name"] as! String)
            let a = try MDZipArchive(data: RawZip.make(names: [entry]))
            XCTAssertEqual(a.contains(lookup), matches, c["name"] as! String)
            XCTAssertEqual(a.entry(at: lookup) != nil, matches)
            if !matches { XCTAssertCode(try a.data(at: lookup), .entryNotFound) }
        }
        report("T-009", "passed")
    }

    func testT010_localeIndependentSupportFiles() throws {
        #if canImport(Glibc) || canImport(Darwin)
        _ = setlocale(LC_ALL, "tr_TR.UTF-8") // may be unavailable; the code never consults the locale
        defer { _ = setlocale(LC_ALL, "C") }
        #endif
        let a = try MDZipArchive(data: RawZip.make(names: ["LICENSE.md", "notes.md"]))
        XCTAssertEqual(try a.entryPoint(), "notes.md")
        XCTAssertEqual(MDZipPath.asciiLowercased("LICENSE"), "license")
        XCTAssertTrue(MDZipPath.isSupportFile(rootLevelName: "LICENSE.md"))
        report("T-010", "passed", "ASCII-only comparison; no locale API is used")
    }

    func testT011_linkResolution() throws {
        let doc = try Fixtures.json("link-resolution-cases.json") as! [String: Any]
        let host = doc["host"] as! [String: Any]
        let archives = host["archives"] as! [String: [String: Any]]
        var applicable = 0, notApplicable = 0
        for c in doc["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let from = c["from"] as! [String: Any]
            guard let archiveName = from["archive"] as? String else { notApplicable += 1; continue }
            applicable += 1
            let entries = archives[archiveName]!["entries"] as! [String]
            let a = try MDZipArchive(data: RawZip.make(names: entries))
            let result = a.resolveLink(c["link"] as! String, from: from["path"] as! String)
            let expected = c["expected"] as! [String: Any]
            switch expected["kind"] as! String {
            case "internal":
                XCTAssertEqual(result, .internalEntry(entry: expected["entry"] as! String,
                                                      fragment: expected["fragment"] as? String), name)
            case "url":
                XCTAssertEqual(result, .external(url: c["link"] as! String), name)
            default:
                // host / archive / unresolved targets need a host filesystem, which this library does not
                // have: the spec's answer for a consumer without that support is "unresolved".
                guard case .unresolved = result else { XCTFail("\(name): got \(result)"); continue }
            }
        }
        report("T-011", "passed", "\(applicable) cases run with outsideLinks/intoArchiveLinks off; \(notApplicable) host-note cases not applicable")
    }

    func testT012_manifestValidation() throws {
        for c in try Fixtures.objects("manifest-cases.json") {
            let name = c["name"] as! String
            let expected = c["expected"] as! [String: Any]
            let text = c["manifestJson"] as! String
            do {
                let m = try MDZipManifest.parse(text)
                XCTAssertEqual(expected["valid"] as? Bool, true, name)
                XCTAssertEqual(Set(m.ignoredFields), Set(expected["ignoredFields"] as? [String] ?? []), name)
                XCTAssertEqual(!m.duplicateMembers.isEmpty, expected["duplicateMembers"] as? Bool ?? false, name)
                for (pointer, value) in expected["values"] as? [String: Any] ?? [:] {
                    XCTAssertEqual(MDZipJSON.object(m.fields).value(atPointer: pointer), .string(value as! String), name)
                }
                // The same manifest inside an archive opens and validates the same way.
                let a = try MDZipArchive(data: RawZip.make(names: [], manifest: text) )
                XCTAssertNotNil(try a.manifest(), name)
            } catch let e as MDZipError {
                XCTAssertEqual(expected["valid"] as? Bool, false, "\(name): \(e)")
                XCTAssertEqual(e.code.rawValue, expected["errorCode"] as? String, name)
                let a = try MDZipArchive(data: RawZip.make(names: [], manifest: text))
                XCTAssertThrowsError(try a.manifest(), name)
            }
        }
        report("T-012", "passed")
    }

    func testT013_entrySets() throws {
        for c in try Fixtures.objects("entry-set-cases.json") {
            let name = c["name"] as! String
            let data = RawZip.make(names: c["entries"] as! [String])
            if c["valid"] as! Bool {
                XCTAssertNoThrow(try MDZipArchive(data: data), name)
            } else {
                XCTAssertThrowsError(try MDZipArchive(data: data), name) {
                    XCTAssertEqual(($0 as? MDZipError)?.code.rawValue, c["errorCode"] as? String, name)
                }
            }
        }
        // Single-name rules (path-validation-cases.json), directly and through opening.
        for c in try Fixtures.objects("path-validation-cases.json") {
            let path = c["path"] as! String
            let code = MDZipPath.validate(entryName: path)
            if c["valid"] as! Bool {
                XCTAssertNil(code, c["name"] as! String)
                XCTAssertNoThrow(try MDZipArchive(data: RawZip.make(names: [path])))
            } else {
                XCTAssertEqual(code?.rawValue, c["errorCode"] as? String, c["name"] as! String)
                XCTAssertThrowsError(try MDZipArchive(data: RawZip.make(names: [path]))) {
                    let e = $0 as? MDZipError
                    XCTAssertEqual(e?.code, .pathInvalid)
                    XCTAssertEqual(e?.detail?.rawValue, c["errorCode"] as? String)
                }
            }
        }
        report("T-013", "passed", "includes path-validation-cases.json")
    }

    func testT014_unsupportedCompression() throws {
        XCTAssertCode(try Fixtures.archive("unsupported-compression.mdz"), .zipInvalid)
        report("T-014", "passed", "rejected with ERR_ZIP_INVALID")
    }

    func testT015_projectMode() throws {
        let a = try Fixtures.archive("project-mode.mdz")
        XCTAssertEqual(try a.mode(), .project)
        XCTAssertEqual(try a.entryPoint(), "index.md")
        var texts = Set<String>()
        for d in ["index.md", "chapters/one.md", "chapters/two.md"] { texts.insert(try a.text(at: d)) }
        XCTAssertEqual(texts.count, 3, "documents are separate, never joined")
        report("T-015", "passed", "project-capable: mode() is .project")
    }

    func testT017_symlinks() throws {
        let doc = try Fixtures.json("archive-cases.json") as! [String: Any]
        let c = (doc["cases"] as! [[String: Any]]).first { $0["id"] as? String == "symlink-entries" }!
        let a = try Fixtures.archive(c["archive"] as! String)
        XCTAssertEqual(try a.entryPoint(), "index.md")
        for (href, name) in [("shortcut.md", "shortcut.md"), ("linked/page.md", ""), ("escape.md", "escape.md")] {
            let r = a.resolveLink(href, from: "index.md")
            guard case .unresolved = r else { XCTFail("\(href) -> \(r)"); continue }
            if !name.isEmpty { XCTAssertFalse(a.contains(name)) }
        }
        XCTAssertEqual(a.resolveLink("notes.md", from: "index.md"), .internalEntry(entry: "notes.md", fragment: nil))
        XCTAssertEqual(a.resolveLink("docs/page.md", from: "index.md"), .internalEntry(entry: "docs/page.md", fragment: nil))
        let symlinks = (c["symlinks"] as! [String: String]).count
        XCTAssertEqual(Set(a.specialEntries.map { $0.path }), Set((c["symlinks"] as! [String: String]).keys))
        XCTAssertEqual(symlinks, 3)
        XCTAssertCode(try a.data(at: "linked"), .entryNotFound)
        XCTAssertEqual(a.validate().warnings.filter { $0.code == "WARN_SYMLINK_ENTRY" }.count, 3)
        report("T-017", "passed", "never followed; each reported (WARN_SYMLINK_ENTRY)")
    }

    func testT018_zipBombs() throws {
        // forged size: opens, but reading stops at the declared size.
        let forged = try Fixtures.archive("limit-forged-size.mdz")
        XCTAssertEqual(try forged.text(at: "index.md").isEmpty, false)
        XCTAssertCode(try forged.data(at: "data/blob.bin"), .limitExceeded)
        // extreme ratio: rejected at open.
        XCTAssertCode(try Fixtures.archive("limit-high-ratio.mdz"), .limitExceeded)
        // overlapping entries: rejected at open.
        XCTAssertThrowsError(try Fixtures.archive("limit-overlapping-entries.mdz")) {
            let code = ($0 as? MDZipError)?.code
            XCTAssertTrue(code == .limitExceeded || code == .zipInvalid)
        }
        // The overlap check alone (limits loosened) still catches it.
        let loose = MDZipLimits(maxEntries: 100_000, maxEntryBytes: 1 << 40, maxTotalBytes: 1 << 50)
        XCTAssertCode(try Fixtures.archive("limit-overlapping-entries.mdz", limits: loose), .zipInvalid)
        report("T-018", "passed", "forged: read fails ERR_LIMIT_EXCEEDED; ratio: open fails ERR_LIMIT_EXCEEDED; overlap: open fails ERR_LIMIT_EXCEEDED (ERR_ZIP_INVALID with loose limits)")
    }

    func testT016_notApplicable() {
        report("T-016", "not-applicable", "library does not render Markdown")
    }
}
