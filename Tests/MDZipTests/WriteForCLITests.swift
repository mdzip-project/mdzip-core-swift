import Foundation
import XCTest
@testable import MDZip

/// Writes sample archives to the folder named by MDZIP_OUT so `mdz validate` can be run on them.
final class WriteForCLITests: XCTestCase {
    func testWriteSamples() throws {
        guard let dir = ProcessInfo.processInfo.environment["MDZIP_OUT"] else { throw XCTSkip("MDZIP_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var b = MDZipBuilder()
        b.setApplication(name: "mdzip-core-swift tests", version: "0.1.0")
        b.metadata["author"] = ["name": "Ada Lovelace"]
        b.metadata["license"] = "MIT"
        try b.addFile("index.md", text: "# Created\n\n![logo](images/logo.png)\n\nSee [more](docs/more.md).\n")
        try b.addFile("docs/more.md", text: "More.\n")
        try b.addFile("images/logo.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        try b.addFile("docs/\u{4e2d}\u{6587}.md", text: "Unicode name\n")
        try b.write(to: out.appendingPathComponent("created.mdz"))

        var p = MDZipBuilder()
        p.mode = .project
        try p.addFile("index.md", text: "# Project\n\n[one](chapters/one.md)\n")
        try p.addFile("chapters/one.md", text: "# One\n")
        try p.write(to: out.appendingPathComponent("project.mdz"))

        let rt = try MDZipArchive(data: Fixtures.data("round-trip.mdz"))
        try rt.updated { e in
            try e.setFile("images/added.png", data: Data([1, 2, 3]))
            try e.updateManifest { $0["title"] = "Edited title" }
        }.write(to: out.appendingPathComponent("round-trip-edited.mdz"))

        let bare = try MDZipArchive(data: Fixtures.data("minimal.mdz"))
        try bare.updated { try $0.setFile("AGENTS.md", text: "# Agents\n") }.write(to: out.appendingPathComponent("minimal-plus-agents.mdz"))

        let sym = try MDZipArchive(data: Fixtures.data("symlink-entries.mdz"))
        var e = try sym.editor()
        e.symlinkPolicy = .storeAsFiles
        try e.setFile("notes.md", text: "edited\n")
        try e.save(to: out.appendingPathComponent("symlinks-repaired.mdz"))
    }
}
