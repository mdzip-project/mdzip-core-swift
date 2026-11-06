import Foundation
import XCTest
@testable import MDZip

/// Producer checks P-001 to P-008 and the round-trip flows.
final class FixtureProducerTests: XCTestCase {
    func testP001_newArchive() throws {
        var b = MDZipBuilder()
        b.setApplication(name: "test-app", version: "1.0", url: "https://example.com")
        try b.addFile("index.md", text: "# Hello\r\n\r\nText\r\n")
        try b.addFile("images/logo.png", data: Data([1, 2, 3]))
        let a = try MDZipArchive(data: try b.build())
        let m = try XCTUnwrap(try a.manifest())
        XCTAssertNotNil(m.specVersion)
        XCTAssertEqual(m.entryPoint, "index.md")
        XCTAssertEqual(m.title, "Hello")
        XCTAssertEqual(m.mode, .document)
        XCTAssertEqual(try a.entryPoint(), "index.md")
        XCTAssertFalse(try a.text(at: "index.md").contains("\r"))
        let r = a.validate()
        XCTAssertTrue(r.isConforming && r.warnings.isEmpty, "\(r.findings)")
        XCTAssertEqual(MDZipJSON.object(m.fields).value(atPointer: "/producer/application/name"), "test-app")
        XCTAssertEqual(MDZipJSON.object(m.fields).value(atPointer: "/producer/core/name"), .string(MDZipCore.name))
        report("P-001", "passed")
    }

    private func edit(_ names: [String], add: String) throws -> MDZipArchive {
        let original = try MDZipArchive(data: RawZip.make(names: names))
        let before = try original.entryPoint()
        let data = try original.updated { try $0.setFile(add, text: "# added\n") }
        let a = try MDZipArchive(data: data)
        XCTAssertEqual(try a.entryPoint(), before)
        XCTAssertEqual(try a.manifest()?.entryPoint, before)
        return a
    }

    func testP002_addSupportFileToManifestLess() throws {
        _ = try edit(["notes.md"], add: "AGENTS.md")
        report("P-002", "passed")
    }

    func testP003_secondSupportFile() throws {
        _ = try edit(["README.md"], add: "AGENTS.md")
        report("P-003", "passed")
    }

    func testP006_modifyManifestLess() throws {
        let a = try edit(["index.md", "other.md"], add: "index.md")
        XCTAssertEqual(try a.entryPoint(), "index.md")
        // Without adding a manifest the entry point also stays the same.
        let original = try MDZipArchive(data: RawZip.make(names: ["notes.md"]))
        var e = try original.editor()
        e.addsManifestIfMissing = false
        try e.setFile("notes.md", text: "changed")
        let b = try MDZipArchive(data: try e.serialize())
        XCTAssertFalse(b.hasManifest)
        XCTAssertEqual(try b.entryPoint(), "notes.md")
        report("P-006", "passed", "manifest added by default; also conforming without")
    }

    func testP007_namesAndFlags() throws {
        var b = MDZipBuilder()
        try b.addFile("index.md", text: "# Caf\u{e9}\n")
        try b.addFile("cafe\u{301}/menu.md", text: "x")           // NFD input is written as NFC
        try b.addFile("data/\u{4e2d}\u{6587}.bin", data: Data(repeating: 7, count: 5000))
        try b.addFile("big.txt", data: Data(String(repeating: "lorem ipsum dolor ", count: 4000).utf8))
        try b.addDirectory("empty")
        let bytes = try b.build()
        let records = try ZipReader.readDirectory(bytes, limits: .default)
        for r in records {
            XCTAssertTrue(r.method == 0 || r.method == 8)
            XCTAssertTrue(r.kind == .file || r.kind == .directory)
            if !r.name.unicodeScalars.allSatisfy({ $0.isASCII }) {
                XCTAssertTrue(r.usesUTF8Flag, "UTF-8 flag on \(r.name)")
                XCTAssertTrue(MDZipPath.normalized(r.name).unicodeScalars.elementsEqual(r.name.unicodeScalars))
            }
        }
        XCTAssertTrue(records.contains { $0.method == 8 }, "something was deflated")
        // No ZIP64: no locator/record signatures and no 0x0001 extra field in any central header.
        let hay = [UInt8](bytes)
        func contains(_ sig: [UInt8]) -> Bool {
            (0...(hay.count - sig.count)).contains { Array(hay[$0..<($0 + 4)]) == sig }
        }
        XCTAssertFalse(contains([0x50, 0x4B, 0x06, 0x07]))
        XCTAssertFalse(contains([0x50, 0x4B, 0x06, 0x06]))
        XCTAssertEqual(try MDZipArchive(data: bytes).manifest()?.duplicateMembers, [])
        XCTAssertEqual(try MDZipArchive(data: bytes).data(at: "caf\u{e9}/menu.md"), Data("x".utf8))
        report("P-007", "passed")
    }

    func testRoundTripFlows_P004_P005() throws {
        let doc = try Fixtures.json("round-trip-expectations.json") as! [String: Any]
        let pointers = doc["preservedManifestValues"] as! [[String: Any]]
        let preserved = doc["preservedEntries"] as! [[String: Any]]
        let flows = doc["flows"] as! [[String: Any]]
        for flow in flows {
            let name = flow["name"] as! String
            var current = try Fixtures.data("round-trip.mdz")
            for pass in 1...2 {
                let archive = try MDZipArchive(data: current)
                var changes = Set(flow["changes"] as? [String] ?? [])
                let removes = Set(flow["removes"] as? [String] ?? [])
                current = try archive.updated { e in
                    switch name {
                    case "change a recognized manifest field":
                        try e.updateManifest { $0["title"] = .string("Edited title \(pass)") }
                    case "edit document content":
                        let t = try archive.text(at: "index.md")
                        try e.setFile("index.md", text: t + "\nAppended \(pass)\n")
                    case "add a resource":
                        try e.setFile("images/added.png", data: Data([0x89, 0x50, 0x4E, 0x47, UInt8(pass)]))
                    case "remove a recognized resource":
                        if pass == 1 {
                            let t = try archive.text(at: "index.md")
                            let kept = t.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains("docs/guide.md") }
                            try e.setFile("index.md", text: kept.joined(separator: "\n"))
                            try e.removeFile("docs/guide.md")
                        }
                    default: break
                    }
                }
                changes.insert("manifest.json")
                let result = try MDZipArchive(data: current)
                let manifest = MDZipJSON.object(try XCTUnwrap(try result.manifest()).fields)
                for p in pointers {
                    let pointer = p["pointer"] as! String
                    let expected = try JSONSerialization.data(withJSONObject: [p["value"]!], options: [])
                    let wrapped = try JSONSerialization.jsonObject(with: expected) as! [Any]
                    _ = wrapped
                    var parser = JSONParser(bytes: [UInt8](expected))
                    let parsed = try parser.parse().arrayValue![0]
                    XCTAssertEqual(manifest.value(atPointer: pointer), parsed, "\(name) pass \(pass) \(pointer)")
                }
                for e in preserved {
                    let path = e["path"] as! String
                    if removes.contains(path) { XCTAssertFalse(result.contains(path), "\(name): \(path) should be gone"); continue }
                    if changes.contains(path) { continue }
                    let data = try result.data(at: path)
                    XCTAssertEqual(data.count, e["bytes"] as! Int, "\(name) pass \(pass) \(path)")
                    XCTAssertEqual(sha256Hex(data), e["sha256"] as! String, "\(name) pass \(pass) \(path)")
                }
                XCTAssertEqual(try result.entryPoint(), "index.md")
                XCTAssertTrue(result.validate().isConforming, name)
            }
        }
        report("P-004", "passed", "5 flows x 2 saves")
        report("P-005", "passed", "5 flows x 2 saves")
    }

    func testP008_modifyArchiveWithSymlinks() throws {
        let a = try Fixtures.archive("symlink-entries.mdz")
        let links = Set(a.specialEntries.map { $0.path })
        XCTAssertEqual(links.count, 3)

        // Default: kept as they were (not new links), and reported.
        var e = try a.editor()
        try e.setFile("notes.md", text: "edited\n")
        XCTAssertFalse(e.warnings.isEmpty)
        let kept = try MDZipArchive(data: try e.serialize())
        XCTAssertEqual(Set(kept.specialEntries.map { $0.path }), links)
        XCTAssertEqual(try kept.text(at: "notes.md"), "edited\n")
        XCTAssertEqual(try kept.entryPoint(), "index.md")

        // Repair: stored as regular files holding the target text.
        var f = try a.editor()
        f.symlinkPolicy = .storeAsFiles
        try f.setFile("notes.md", text: "edited\n")
        let files = try MDZipArchive(data: try f.serialize())
        XCTAssertTrue(files.specialEntries.isEmpty)
        XCTAssertEqual(try files.text(at: "shortcut.md"), "notes.md")

        // Repair: removed (the caller asked).
        var g = try a.editor()
        g.symlinkPolicy = .remove
        let removed = try MDZipArchive(data: try g.serialize())
        XCTAssertTrue(removed.specialEntries.isEmpty)
        XCTAssertFalse(removed.contains("shortcut.md"))
        report("P-008", "passed", "kept and reported by default; .storeAsFiles / .remove on request")
    }
}
