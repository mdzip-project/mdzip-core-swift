# mdzip-core-swift

Read, write and validate **MDZip** (`.mdz`) archives in Swift: one or more Markdown documents and their images and other assets, packaged in a single ZIP file.

This package implements the [MDZip specification](https://github.com/mdzip-project/mdzip-spec) 1.2.1 and the required operations (R1 to R7) of the [core library contract](https://github.com/mdzip-project/.github/blob/main/docs/core-contract.md). It does not render Markdown. Status: 0.1.0, not yet released or tagged.

- Swift tools 5.9+, for macOS 12+, iOS 15+ and Linux (the platforms declared in `Package.swift`). CI runs the tests on Linux (`swift:6.1`), macOS (`macos-15`) and the iOS Simulator. No Apple-only APIs are used. To run the tests yourself on a Mac, in the iOS Simulator or on an iPhone, see [Testing on a Mac, the iOS Simulator and an iPhone](docs/testing-on-mac-and-iphone.md).
- One dependency: [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 0.9.20 (MIT), used only to write archives. See [ZIP library](#zip-library).

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/mdzip-project/mdzip-core-swift.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "MDZip", package: "mdzip-core-swift")]),
]
```

## Quick usage

```swift
import MDZip

// Read
let archive = try MDZipArchive(contentsOf: url)            // or MDZipArchive(data:)
let entry = try archive.entryPoint()                       // "index.md" (Section 5.5)
let text = try archive.text(at: entry)
let logo = try archive.data(at: "images/logo.png")
print(try archive.manifest()?.title as Any, try archive.mode())

switch archive.resolveLink("../images/logo.png#x", from: "chapters/intro.md") {
case .internalEntry(let path, let fragment): print(path, fragment as Any)
case .external(let url): print(url)
case .unresolved(let reason): print(reason)
}

for finding in archive.validate().findings { print(finding.severity, finding.code, finding.message) }

// Create
var builder = MDZipBuilder()
builder.setApplication(name: "My App", version: "1.0")
try builder.addFile("index.md", text: "# My Guide\n")
try builder.addFile("images/logo.png", data: pngBytes)
try builder.write(to: outURL)                              // atomic

// Modify
var editor = try archive.editor()
try editor.setFile("notes.md", text: "# Notes\n")
try editor.removeFile("old.md")
try editor.updateManifest { $0["title"] = "Second edition" }
try editor.save(to: url)                                   // on any failure the original file is untouched
```

Errors are `MDZipError` values. Check `error.code` (an `MDZipErrorCode` such as `.entryPointMissing`); `error.message` is for people. For bad entry names `error.code` is `.pathInvalid` and `error.detail` is the specific code (for example `.pathTraversal`).

## R1 to R7 and the public API

| ID | Operation | Public API |
|---|---|---|
| R1 | Open/read an archive | `MDZipArchive(data:limits:)`, `MDZipArchive(contentsOf:limits:)`. Input is bytes or a file; the archive is held in memory and nothing is extracted. |
| R2 | Inspect entries and metadata | `entries`, `files`, `directories`, `specialEntries`, `contains(_:)`, `entry(at:)`, `data(at:)`, `text(at:)` (strict UTF-8), `nearMatch(for:)`, `manifest()`, `entryPoint()`, `mode()`, `cover()` |
| R3 | Resolve a link | `resolveLink(_:from:)` returns `.internalEntry`, `.external` or `.unresolved(reason)`, keeping the fragment. |
| R4 | Validate | `validate()` and `MDZipArchive.validate(data:limits:)` return an `MDZipValidationReport` (errors, warnings, notes, each with a stable `code`). `MDZipManifest.parse(_:)` validates a manifest on its own. |
| R5 | Create | `MDZipBuilder` (`addFile`, `addDirectory`, `title`, `mode`, `entryPoint`, `metadata`, `setApplication`, `build()`, `write(to:)`) |
| R6 | Modify | `MDZipArchive.editor()` returns an `MDZipEditor` (`setFile`, `removeFile`, `updateManifest`, `setEntryPoint`, `symlinkPolicy`, `serialize()`, `save(to:)`); `updated(_:)` for a one-shot edit. |
| R7 | Safety | Checked in `MDZipArchive.init`, `data(at:)` and the editor: entry names, duplicates and conflicts, methods other than 0 and 8, encryption, symbolic links, `MDZipLimits`. |

Links outside the archive and into other archives (spec Sections 9.4 and 9.5) are optional and need a host filesystem, which this library does not have. They resolve to `.unresolved(.unsupported)`: never clamped at the archive root and never mapped to a file inside the archive.

### What the library guarantees

- **Entry point.** A declared `entryPoint` that is malformed fails with `ERR_ENTRYPOINT_INVALID` and one that names no file fails with `ERR_ENTRYPOINT_MISSING` (including a case-only difference). There is never a silent fallback to `index.md` or `README.md`.
- **Paths.** Matched case-sensitively after NFC, by code point. Support file names (README, AGENTS, LICENSE, CHANGELOG, CONTRIBUTING) and `.md`/`.markdown` are compared ASCII case-insensitively with no locale API.
- **Writing.** Only methods 0 and 8, the UTF-8 flag on non-ASCII names, NFC names, LF in Markdown added as text, and no ZIP64 records unless a value needs them. New entries never have symbolic links.
- **Modifying.** Entries you do not change keep their path and bytes. Every manifest member is kept, including unknown ones at any depth (the manifest is held as ordered JSON, not a typed model). The entry point keeps resolving to the same file; edits that remove it are rejected. A manifest is added to an archive that has none (disable with `addsManifestIfMissing`). Symbolic links in an archive being edited are kept and reported by default; `symlinkPolicy` can store them as files or remove them. Saving replaces the file atomically.

## Error codes

| Code | Meaning |
|---|---|
| `ERR_ZIP_INVALID` | Not a ZIP, damaged data, bad CRC, overlapping entries, or a method other than 0 or 8 |
| `ERR_ZIP_ENCRYPTED` | Encrypted entry |
| `ERR_PATH_INVALID` | Bad entry name; `detail` is one of `ERR_PATH_LEADING_SLASH`, `ERR_PATH_TRAVERSAL`, `ERR_PATH_RESERVED_CHAR`, `ERR_PATH_CONTROL_CHAR` or `ERR_PATH_INVALID` (empty or `.` segment) |
| `ERR_DUPLICATE_PATH`, `ERR_PATH_CONFLICT` | Equal names after NFC; a file that is also a directory |
| `ERR_MANIFEST_INVALID`, `ERR_VERSION_UNSUPPORTED`, `ERR_MODE_UNSUPPORTED` | Manifest problems (Section 6.4). Raised by `manifest()`, not by opening, so a bad manifest can still be inspected. |
| `ERR_ENTRYPOINT_INVALID`, `ERR_ENTRYPOINT_MISSING`, `ERR_ENTRYPOINT_UNRESOLVED` | Entry point problems (Section 5.5) |
| `ERR_LIMIT_EXCEEDED` | A resource limit, declared or actual |
| `ERR_ENTRY_NOT_FOUND`, `ERR_TEXT_DECODING`, `ERR_SPECIAL_ENTRY`, `ERR_INVALID_ARGUMENT`, `ERR_IO` | Library-specific (not in the specification) |

Validation warnings and notes: `WARN_FIELD_IGNORED`, `WARN_DUPLICATE_MEMBER`, `WARN_SPEC_VERSION_OLDER`, `WARN_COVER_MISSING`, `WARN_SYMLINK_ENTRY`, `WARN_CASE_COLLISION`, `WARN_UTF8_FLAG_MISSING`, `WARN_PATH_NOT_NFC`; `NOTE_NO_MANIFEST`, `NOTE_NO_SPEC_VERSION`. A missing manifest is a note, never a warning.

## Safety limits

`MDZipLimits` (defaults; all no looser than the fixtures' reference limits):

| Limit | Default |
|---|---|
| Entries | 20,000 |
| One entry, uncompressed | 256 MiB |
| All entries, uncompressed | 1 GiB |
| Compression ratio (entries over 1 MiB) | 1000:1 |

Declared sizes are checked when opening. Because they can lie, reads are checked too: the decompressor stops as soon as an entry would pass its declared size and fails with `ERR_LIMIT_EXCEEDED`, so an entry never returns more than it declared. Entries whose data overlaps another's are rejected, and every central-directory entry is listed or the archive is rejected. Symbolic links and other special entries are listed in `specialEntries`, never read, resolved to or followed, and reported by `validate()`. Pass your own `MDZipLimits` to change the defaults.

## ZIP library

ZIPFoundation was evaluated first against the brief's rules, by reading its source (0.9.20).

| Rule | ZIPFoundation |
|---|---|
| Write only methods 0 and 8 | Yes (`CompressionMethod` has only those) |
| UTF-8 flag | Yes (bit 11 on every name) |
| No unnecessary ZIP64 | Yes: ZIP64 fields are written only when a size, offset or count overflows |
| Symlink entries | Yes: `Entry.type == .symlink` |
| Stop at the declared size when reading | Only through a consumer closure, and the Linux inflate loop does not limit input to the entry's compressed size |
| Reject hostile structure | No. Its entry iterator ends silently at the first unreadable local header, which hides central-directory entries (the overlapping-entries bomb). Names are not cross-checked and overlapping data is not detected. |
| Truncated DEFLATE data | The Linux decode loop repeats until `Z_STREAM_END`, with no exit at end of input |

So ZIPFoundation meets the writing rules and is used for writing: DEFLATE compression and the ZIP structures. The reading side is this package's own, because the rules above ("check the bytes actually decompressed", "limit the entry count" and "never hide entries") cannot be met through its API:

- `ZipReader.swift` reads the central directory (including ZIP64), validates every record and local header, and rejects overlapping data.
- `Inflate.swift` is a bounded raw-DEFLATE decoder (after zlib's `puff.c`, about 200 lines). It stops at the declared size, never reads past the entry's compressed bytes and fails on truncated input.

The inflater is tested beyond the fixtures: against streams produced by Python's zlib (fixed, dynamic and stored blocks, runs, empty input), against damaged and truncated streams and random garbage, at its output limit, and by reading a 3 MB archive whose entries were deflated by zlib (through ZIPFoundation) and comparing the bytes.

## Tests and fixture results

The fixtures are copied from the spec tag v1.2.1 with `node ../mdzip-spec/tools/sync-fixtures.mjs Tests/MDZipTests/Fixtures --ref v1.2.1` (`SPEC-FIXTURES.json` records the tag and checksums) and are not edited. Run the tests with the pinned image:

```sh
docker run --rm -v "$PWD:/work" -w /work swift:6.1 swift test
```

Each fixture test prints a `FIXTURE-RESULT` line. All 41 tests pass.

| ID | Result | Note |
|---|---|---|
| T-001 to T-005 | passed | |
| T-006 | passed | `entrypoint-cases.json` support-file cases |
| T-007 | passed | no warning for a missing manifest (a note only) |
| T-008 | passed | `entrypoint-cases.json` error cases |
| T-009 | passed | `path-matching-cases.json` |
| T-010 | passed | no locale API is used; the test also tries to set `tr_TR` |
| T-011 | passed | 42 cases run with outside and into-archive links off (must be unresolved); 11 cases that start from a host note are not applicable |
| T-012 | passed | `manifest-cases.json` |
| T-013 | passed | `entry-set-cases.json` and `path-validation-cases.json`, also through opening |
| T-014 | passed | rejected with `ERR_ZIP_INVALID` |
| T-015 | passed | project-capable: `mode()` is `.project`, documents are separate |
| T-016 | not applicable | the library does not render |
| T-017 | passed | never followed; each reported |
| T-018 | passed | forged size fails on read, high ratio and overlap fail on open, all `ERR_LIMIT_EXCEEDED`; overlap alone gives `ERR_ZIP_INVALID` |
| P-001 to P-003 | passed | |
| P-004, P-005 | passed | five flows, each saved twice |
| P-006, P-007 | passed | |
| P-008 | passed | symbolic links kept and reported by default |

`mdz validate` (CLI 2.0.0) reports "valid" with no warnings on archives the library wrote in Docker: a created archive (with application, author, a Unicode name), a project-mode archive, `round-trip.mdz` after an edit, `minimal.mdz` plus an `AGENTS.md`, and `symlink-entries.mdz` with its links stored as files. Set `MDZIP_OUT` to a folder when running the tests to write these samples.

## What's left to do

- Not yet run on a physical iPhone (CI covers the iOS Simulator; see the testing guide).
- No release, tag or Swift Package Index entry yet.
- Not implemented (optional extensions): configurable limits are available, but there is no image analysis, workspace model, directory packing, MIME helpers or safe extraction to disk.
- Links outside the archive and into other archives (Sections 9.4 and 9.5) need a host filesystem and are unresolved.
- Large archives are read and written in memory; there is no streaming API.
- `modified.by` is not set on edits.
- Writing relies on ZIPFoundation 0.9.20 for DEFLATE; entries are rewritten rather than copied as raw compressed bytes.

## License

Apache License 2.0, as the other MDZip cores. ZIPFoundation is MIT licensed.
