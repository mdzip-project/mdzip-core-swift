import Foundation

/// A JSON value that keeps what a typed model would lose: member order, the exact text of
/// numbers, and every member of an object. The manifest is held in this form so fields the
/// library does not know survive a rewrite (Section 6.3).
public enum MDZipJSON: Sendable {
    case null
    case bool(Bool)
    case number(MDZipJSONNumber)
    case string(String)
    case array([MDZipJSON])
    case object(MDZipJSONObject)

    public static func int(_ value: Int) -> MDZipJSON { .number(MDZipJSONNumber(lexeme: String(value))) }

    /// The string value, if this is a string.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The object value, if this is an object.
    public var objectValue: MDZipJSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// The array value, if this is an array.
    public var arrayValue: [MDZipJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Looks up a JSON Pointer (RFC 6901), such as `/producer/application/name`.
    public func value(atPointer pointer: String) -> MDZipJSON? {
        if pointer.isEmpty { return self }
        guard pointer.hasPrefix("/") else { return nil }
        var current = self
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let o):
                guard let next = o[token] else { return nil }
                current = next
            case .array(let a):
                guard let i = Int(token), i >= 0, i < a.count else { return nil }
                current = a[i]
            default:
                return nil
            }
        }
        return current
    }
}

/// A JSON number, kept as written.
public struct MDZipJSONNumber: Sendable, Hashable {
    /// The number's JSON text, for example `3.5` or `1e3`.
    public let lexeme: String
    public init(lexeme: String) { self.lexeme = lexeme }
    public init(_ value: Double) { self.lexeme = value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value) }
    public var doubleValue: Double { Double(lexeme) ?? .nan }
}

/// A JSON object with its members in their original order.
public struct MDZipJSONObject: Sendable {
    public private(set) var members: [(key: String, value: MDZipJSON)]

    public init() { members = [] }
    public init(_ members: [(key: String, value: MDZipJSON)]) {
        self.members = []
        for m in members { self[m.key] = m.value }
    }

    public var keys: [String] { members.map { $0.key } }

    // Compares keys scalar by scalar: Swift's String == treats canonically equivalent
    // text as equal, and JSON member names are distinct if their code points differ.
    private func indexOfMember(_ key: String) -> Int? {
        members.firstIndex(where: { $0.key.unicodeScalars.elementsEqual(key.unicodeScalars) })
    }
    public var isEmpty: Bool { members.isEmpty }

    /// Gets, sets (keeping a member's position) or, with `nil`, removes a member.
    public subscript(key: String) -> MDZipJSON? {
        get { indexOfMember(key).map { members[$0].value } }
        set {
            if let i = indexOfMember(key) {
                if let v = newValue { members[i].value = v } else { members.remove(at: i) }
            } else if let v = newValue {
                members.append((key, v))
            }
        }
    }
}

extension MDZipJSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, MDZipJSON)...) {
        self.init(elements.map { (key: $0.0, value: $0.1) })
    }
}

extension MDZipJSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension MDZipJSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension MDZipJSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension MDZipJSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MDZipJSON...) { self = .array(elements) }
}
extension MDZipJSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, MDZipJSON)...) {
        self = .object(MDZipJSONObject(elements.map { (key: $0.0, value: $0.1) }))
    }
}

// JSON equality: objects ignore member order, numbers compare by value.
extension MDZipJSON: Equatable {
    public static func == (lhs: MDZipJSON, rhs: MDZipJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a.lexeme == b.lexeme || a.doubleValue == b.doubleValue
        case (.string(let a), .string(let b)): return a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        default: return false
        }
    }
}

extension MDZipJSONObject: Equatable {
    public static func == (lhs: MDZipJSONObject, rhs: MDZipJSONObject) -> Bool {
        guard lhs.members.count == rhs.members.count else { return false }
        for m in lhs.members {
            guard let other = rhs[m.key], other == m.value else { return false }
        }
        return true
    }
}

// MARK: - Parsing

struct JSONSyntaxError: Error {
    let message: String
}

/// A strict RFC 8259 parser over UTF-8 bytes. Duplicate member names are kept out of the
/// result (the last value wins, at the position of the first) and reported by JSON Pointer.
struct JSONParser {
    private let b: [UInt8]
    private var i = 0
    private(set) var duplicates: [String] = []
    private let maxDepth = 128

    init(bytes: [UInt8]) {
        // A UTF-8 byte order mark is tolerated (RFC 8259 Section 8.1).
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            b = Array(bytes[3...])
        } else {
            b = bytes
        }
    }

    mutating func parse() throws -> MDZipJSON {
        skipWhitespace()
        let v = try value(depth: 0, pointer: "")
        skipWhitespace()
        if i != b.count { throw err("unexpected data after the JSON value") }
        return v
    }

    private func err(_ m: String) -> JSONSyntaxError { JSONSyntaxError(message: "\(m) (at byte \(i))") }

    private mutating func skipWhitespace() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    private mutating func value(depth: Int, pointer: String) throws -> MDZipJSON {
        guard depth <= maxDepth else { throw err("nesting is too deep") }
        guard i < b.count else { throw err("unexpected end") }
        switch b[i] {
        case UInt8(ascii: "{"): return try object(depth: depth, pointer: pointer)
        case UInt8(ascii: "["): return try array(depth: depth, pointer: pointer)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
        default: throw err("unexpected character")
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<(i + w.count)]) == w else { throw err("invalid literal") }
        i += w.count
    }

    private mutating func number() throws -> MDZipJSON {
        let start = i
        if b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count else { throw err("invalid number") }
        if b[i] == UInt8(ascii: "0") {
            i += 1
        } else if b[i] >= UInt8(ascii: "1") && b[i] <= UInt8(ascii: "9") {
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
        } else {
            throw err("invalid number")
        }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            let digits = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            if i == digits { throw err("invalid number") }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            let digits = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            if i == digits { throw err("invalid number") }
        }
        return .number(MDZipJSONNumber(lexeme: String(decoding: b[start..<i], as: UTF8.self)))
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count else { throw err("invalid escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw err("invalid escape")
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    private mutating func string() throws -> String {
        i += 1 // opening quote
        var out = [UInt8]()
        while true {
            guard i < b.count else { throw err("unterminated string") }
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw err("control character in string") }
            if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { throw err("unterminated string") }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4()
                if (0xD800...0xDBFF).contains(scalar) {
                    guard i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else {
                        throw err("unpaired surrogate")
                    }
                    i += 2
                    let low = try hex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw err("unpaired surrogate") }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    throw err("unpaired surrogate")
                }
                guard let u = Unicode.Scalar(scalar) else { throw err("invalid escape") }
                out.append(contentsOf: Array(String(Character(u)).utf8))
            default: throw err("invalid escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private mutating func array(depth: Int, pointer: String) throws -> MDZipJSON {
        i += 1
        var items: [MDZipJSON] = []
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try value(depth: depth + 1, pointer: pointer + "/\(items.count)"))
            skipWhitespace()
            guard i < b.count else { throw err("unterminated array") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "]") { i += 1; break }
            throw err("expected , or ]")
        }
        return .array(items)
    }

    private mutating func object(depth: Int, pointer: String) throws -> MDZipJSON {
        i += 1
        var obj = MDZipJSONObject()
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
        while true {
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw err("expected a member name") }
            let key = try string()
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw err("expected :") }
            i += 1
            skipWhitespace()
            let childPointer = pointer + "/" + JSONParser.escape(key)
            let v = try value(depth: depth + 1, pointer: childPointer)
            if obj[key] != nil { duplicates.append(childPointer) }
            obj[key] = v
            skipWhitespace()
            guard i < b.count else { throw err("unterminated object") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "}") { i += 1; break }
            throw err("expected , or }")
        }
        return .object(obj)
    }
}

// MARK: - Serializing

extension MDZipJSON {
    /// The JSON text: two-space indentation, LF line endings, members in order, and a final newline.
    public func serialized() -> String {
        var out = ""
        write(to: &out, indent: 0)
        return out + "\n"
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    private func write(to out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closePad = String(repeating: "  ", count: indent)
        switch self {
        case .null: out += "null"
        case .bool(let v): out += v ? "true" : "false"
        case .number(let n): out += n.lexeme
        case .string(let s): out += MDZipJSON.quote(s)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            for (n, v) in a.enumerated() {
                out += pad
                v.write(to: &out, indent: indent + 1)
                out += n == a.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{\n"
            for (n, m) in o.members.enumerated() {
                out += pad + MDZipJSON.quote(m.key) + ": "
                m.value.write(to: &out, indent: indent + 1)
                out += n == o.members.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        }
    }
}
