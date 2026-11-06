import Foundation
import XCTest
@testable import MDZip

/// Tests beyond the shared fixtures: the inflater, limits, safety and failure behavior.
final class LibraryTests: XCTestCase {
    // MARK: Inflate

    private func inflate(_ bytes: [UInt8], limit: Int = 1 << 24) throws -> [UInt8] {
        try bytes.withUnsafeBufferPointer { try Inflate.inflate($0, limit: limit, expectedSize: 0) }
    }

    func testInflateMatchesZlibOutput() throws {
        for v in ZlibVectors.all {
            let plain = [UInt8](Data(base64Encoded: v.plain)!)
            let deflated = [UInt8](Data(base64Encoded: v.deflated)!)
            XCTAssertEqual(try inflate(deflated), plain, v.name)
        }
    }

    func testInflateRejectsDamagedAndTruncatedStreams() throws {
        let v = ZlibVectors.all.first { $0.name == "dynamic" }!
        let good = [UInt8](Data(base64Encoded: v.deflated)!)
        XCTAssertThrowsError(try inflate(Array(good.dropLast(10)))) // truncated: fails, does not hang
        XCTAssertThrowsError(try inflate([]))
        XCTAssertThrowsError(try inflate([0x07])) // reserved block type 3
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 { // random garbage never crashes or hangs
            let junk = (0..<64).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = try? inflate(junk, limit: 1 << 16)
        }
    }

    func testInflateStopsAtLimit() throws {
        let v = ZlibVectors.all.first { $0.name == "runs" }!
        let deflated = [UInt8](Data(base64Encoded: v.deflated)!)
        XCTAssertThrowsError(try inflate(deflated, limit: 100)) {
            guard case Inflate.Failure.limit = $0 else { return XCTFail("\($0)") }
        }
    }

    func testLargeArchiveRoundTripThroughZlibWriter() throws {
        // The writer deflates with zlib (ZIPFoundation); the reader here inflates it again.
        var text = ""
        var x: UInt64 = 12345
        let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
        while text.utf8.count < 3_000_000 {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            text += words[Int(x >> 60) % words.count] + ((x >> 40) % 11 == 0 ? "\n" : " ")
        }
        var noise = Data()
        for _ in 0..<200_000 { x = x &* 6364136223846793005 &+ 1442695040888963407; noise.append(UInt8(truncatingIfNeeded: x >> 33)) }
        var b = MDZipBuilder()
        try b.addFile("index.md", text: "# Big\n" + text)
        try b.addFile("noise.bin", data: noise)
        let bytes = try b.build()
        let a = try MDZipArchive(data: bytes)
        XCTAssertEqual(a.entry(at: "index.md")?.compressionMethod, 8)
        XCTAssertLessThan(bytes.count, 3_200_000 / 2)
        XCTAssertEqual(try a.text(at: "index.md"), "# Big\n" + text)
        XCTAssertEqual(try a.data(at: "noise.bin"), noise)
    }

    // MARK: Limits

    func testConfiguredEntryCountLimit() throws {
        let data = RawZip.make(names: (0..<20).map { "f\($0).md" })
        XCTAssertCode(try MDZipArchive(data: data, limits: MDZipLimits(maxEntries: 10)), .limitExceeded)
        XCTAssertNoThrow(try MDZipArchive(data: data, limits: MDZipLimits(maxEntries: 20)))
    }

    func testDeclaredSizeLimits() throws {
        let data = RawZip.make([("a.md", Data(count: 100)), ("b.md", Data(count: 100))])
        XCTAssertCode(try MDZipArchive(data: data, limits: MDZipLimits(maxEntryBytes: 50)), .limitExceeded)
        XCTAssertCode(try MDZipArchive(data: data, limits: MDZipLimits(maxTotalBytes: 150)), .limitExceeded)
    }

    func testNeverSubstitutesDifferentCase() throws {
        let a = try MDZipArchive(data: RawZip.make(names: ["index.md"]))
        XCTAssertFalse(a.contains("Index.md"))
        XCTAssertCode(try a.data(at: "Index.md"), .entryNotFound)
        XCTAssertEqual(a.nearMatch(for: "Index.md"), "index.md")
    }

    func testInvalidUTF8TextIsAnError() throws {
        let a = try MDZipArchive(data: RawZip.make([("bad.md", Data([0xFF, 0xFE, 0x41]))]))
        XCTAssertCode(try a.text(at: "bad.md"), .textDecoding)
        XCTAssertEqual(try a.data(at: "bad.md").count, 3)
    }

    func testCorruptCRCIsRejected() throws {
        var data = RawZip.make([("a.md", Data("hello".utf8))])
        let i = data.range(of: Data("hello".utf8))!.lowerBound
        data[i] = 0x48
        let a = try MDZipArchive(data: data)
        XCTAssertCode(try a.data(at: "a.md"), .zipInvalid)
    }

    func testNotAZip() {
        XCTAssertCode(try MDZipArchive(data: Data("hello world, not a zip".utf8)), .zipInvalid)
        XCTAssertCode(try MDZipArchive(data: Data()), .zipInvalid)
    }

    // MARK: Manifest

    func testUnknownManifestFieldsSurviveEdits() throws {
        let manifest = #"{"spec":{"version":"1.2.0","x-a":[1,{"b":null}]},"entryPoint":"index.md","x-big":12345678901234567890,"x-num":3.50,"x-dup":1,"x-dup":2}"#
        let a = try MDZipArchive(data: RawZip.make([("index.md", Data("# t".utf8)), ("manifest.json", Data(manifest.utf8))]))
        let out = try MDZipArchive(data: try a.updated { try $0.setFile("n.md", text: "n") })
        let text = String(decoding: try out.data(at: "manifest.json"), as: UTF8.self)
        XCTAssertTrue(text.contains("12345678901234567890"))
        XCTAssertTrue(text.contains("3.50"))
        XCTAssertEqual(text.components(separatedBy: "\"x-dup\"").count, 2, "duplicates written once")
        XCTAssertEqual(MDZipJSON.object(try XCTUnwrap(try out.manifest()).fields).value(atPointer: "/x-dup"), 2)
        XCTAssertEqual(MDZipJSON.object(try XCTUnwrap(try out.manifest()).fields).value(atPointer: "/spec/x-a/1/b"), .null)
    }

    func testModifiedTimestampOnlyWhenChanged() throws {
        let a = try Fixtures.archive("with-manifest.mdz")
        let untouched = try MDZipArchive(data: try a.editor().serialize())
        let original = MDZipJSON.object(try XCTUnwrap(try a.manifest()).fields).value(atPointer: "/modified/when")
        XCTAssertEqual(MDZipJSON.object(try XCTUnwrap(try untouched.manifest()).fields).value(atPointer: "/modified/when"), original)
        let touched = try MDZipArchive(data: try a.updated { try $0.setFile("x.md", text: "x") })
        XCTAssertNotEqual(MDZipJSON.object(try XCTUnwrap(try touched.manifest()).fields).value(atPointer: "/modified/when"), original)
    }

    // MARK: Failed writes

    func testRejectedEditLeavesOriginalFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdzip-\(UUID().uuidString).mdz")
        defer { try? FileManager.default.removeItem(at: url) }
        try Fixtures.data("with-manifest.mdz").write(to: url)
        let before = try Data(contentsOf: url)
        var e = try MDZipArchive(contentsOf: url).editor()
        let ep = try MDZipArchive(contentsOf: url).entryPoint()
        try e.removeFile(ep)
        XCTAssertCode(try e.save(to: url), .entryPointMissing)
        XCTAssertEqual(try Data(contentsOf: url), before)

        // A destination that cannot be written reports ERR_IO and changes nothing.
        let bad = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.mdz")
        var ok = try MDZipArchive(contentsOf: url).editor()
        try ok.setFile("more.md", text: "more")
        XCTAssertCode(try ok.save(to: bad), .io)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testSaveRoundTripOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdzip-\(UUID().uuidString).mdz")
        defer { try? FileManager.default.removeItem(at: url) }
        var b = MDZipBuilder()
        try b.addFile("index.md", text: "# Disk\n")
        try b.write(to: url)
        var e = try MDZipArchive(contentsOf: url).editor()
        try e.setFile("two.md", text: "2")
        try e.save(to: url)
        let a = try MDZipArchive(contentsOf: url)
        XCTAssertTrue(a.contains("two.md"))
        XCTAssertEqual(try a.entryPoint(), "index.md")
    }

    // MARK: Builder rules

    func testBuilderRules() throws {
        var b = MDZipBuilder()
        XCTAssertCode(try b.addFile("../x.md", text: ""), .pathInvalid)
        XCTAssertCode(try b.addFile("manifest.json", text: "{}"), .invalidArgument)
        try b.addFile("a.md", text: "a")
        try b.addFile("b.md", text: "b")
        XCTAssertCode(try b.build(), .entryPointUnresolved)
        b.entryPoint = "c.md"
        XCTAssertCode(try b.build(), .entryPointMissing)
        b.entryPoint = "A.md"
        XCTAssertCode(try b.build(), .entryPointMissing)
        b.entryPoint = "b.md"
        b.mode = .project
        b.metadata["title"] = .int(5)
        b.title = "ok"
        b.metadata["author"] = "not an object"
        XCTAssertCode(try b.build(), .manifestInvalid)
        b.metadata["author"] = ["name": "Ada"]
        let a = try MDZipArchive(data: try b.build())
        XCTAssertEqual(try a.mode(), .project)
        XCTAssertEqual(try a.entryPoint(), "b.md")
        try b.addFile("docs", data: Data())
        try b.addFile("docs/x.md", text: "")
        XCTAssertCode(try b.build(), .pathConflict)
    }

    func testLinkResolutionDetails() throws {
        let a = try MDZipArchive(data: RawZip.make(names: ["index.md", "chapters/intro.md", "My Notes.md", "caf\u{e9}.md"]))
        XCTAssertEqual(a.resolveLink("../My%20Notes.md#top", from: "chapters/intro.md"), .internalEntry(entry: "My Notes.md", fragment: "top"))
        XCTAssertEqual(a.resolveLink("cafe\u{301}.md", from: "index.md"), .internalEntry(entry: "caf\u{e9}.md", fragment: nil))
        XCTAssertEqual(a.resolveLink("mailto:a@b.c", from: "index.md"), .external(url: "mailto:a@b.c"))
        XCTAssertEqual(a.resolveLink("../index.md", from: "index.md"), .unresolved(.unsupported))
    }
}
