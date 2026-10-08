import Foundation

/// 문자열 리터럴. 원본에서 읽은 것은 `raw`(따옴표 포함 원문)를 들고 있어서, 건드리지 않으면 이스케이프 방식까지 그대로 다시 쓴다.
public struct JSONString: Equatable, Sendable {
    public var value: String
    var raw: String?

    public init(_ value: String) {
        self.value = value
        self.raw = nil
    }

    init(value: String, raw: String) {
        self.value = value
        self.raw = raw
    }

    public static func == (lhs: JSONString, rhs: JSONString) -> Bool { lhs.value == rhs.value }

    /// 원문이 있으면 원문, 없으면 JSON 규격대로 이스케이프한 리터럴(`/`와 비ASCII는 그대로 둔다).
    var literal: String {
        if let raw { return raw }
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case let s where s.value < 0x20:
                out += "\\u" + String(format: "%04x", s.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

public struct JSONMember: Equatable, Sendable {
    public var key: JSONString
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = JSONString(key)
        self.value = value
    }

    init(key: JSONString, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// 키 순서를 보존하는 JSON 값. 설정 파일을 읽고 고쳐 쓸 때 사용자의 다른 키와 순서, 숫자 표기를 건드리지 않으려고 직접 만들었다.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// 원문 그대로(`1e3`, `1.0` 등 표기를 잃지 않으려고 문자열로 둔다).
    case number(String)
    case string(JSONString)
    case array([JSONValue])
    case object([JSONMember])

    public static func string(_ value: String) -> JSONValue { .string(JSONString(value)) }

    public var stringValue: String? {
        if case .string(let s) = self { return s.value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [JSONMember]? {
        if case .object(let members) = self { return members }
        return nil
    }

    /// 객체의 첫 번째 `key` 멤버 값.
    public subscript(key: String) -> JSONValue? {
        objectValue?.first { $0.key.value == key }?.value
    }
}

// MARK: - 문서 (값 + 표기 정보)

public struct JSONParseError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public var line: Int
    public var column: Int
    public var description: String { "JSON 구문 오류 (\(line)행 \(column)열): \(message)" }
}

/// 파싱한 JSON과 다시 쓸 때 필요한 표기 정보(들여쓰기 단위, 끝 개행, BOM).
public struct JSONDocument: Equatable, Sendable {
    public var root: JSONValue
    public var indent: String
    public var trailingNewline: Bool
    public var hasBOM: Bool

    public init(root: JSONValue, indent: String = "  ", trailingNewline: Bool = true, hasBOM: Bool = false) {
        self.root = root
        self.indent = indent
        self.trailingNewline = trailingNewline
        self.hasBOM = hasBOM
    }

    /// 비었거나 공백뿐인 입력은 `{}`로 본다(막 만든 빈 설정 파일).
    public static func parse(_ data: Data) throws -> JSONDocument {
        var bytes = [UInt8](data)
        var hasBOM = false
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasBOM = true
            bytes.removeFirst(3)
        }
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return JSONDocument(root: .object([]), hasBOM: hasBOM)
        }
        var parser = JSONParser(bytes: bytes)
        let root = try parser.parseDocument()
        return JSONDocument(
            root: root,
            indent: detectIndent(bytes),
            trailingNewline: bytes.last == 0x0A,
            hasBOM: hasBOM)
    }

    /// 첫 번째로 들여쓴 줄의 공백/탭을 단위로 쓴다. 한 줄짜리 JSON이면 기본값(2칸).
    private static func detectIndent(_ bytes: [UInt8]) -> String {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                var end = index + 1
                while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
                if end > index + 1, end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D {
                    return String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                }
            }
            index += 1
        }
        return "  "
    }

    public func render() -> String {
        var out = hasBOM ? "\u{FEFF}" : ""
        JSONDocument.write(root, indent: indent, level: 0, into: &out)
        if trailingNewline { out += "\n" }
        return out
    }

    private static func write(_ value: JSONValue, indent: String, level: Int, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let text): out += text
        case .string(let s): out += s.literal
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            let inner = String(repeating: indent, count: level + 1)
            out += "[\n"
            for (offset, item) in items.enumerated() {
                out += inner
                write(item, indent: indent, level: level + 1, into: &out)
                out += offset == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: indent, count: level) + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            let inner = String(repeating: indent, count: level + 1)
            out += "{\n"
            for (offset, member) in members.enumerated() {
                out += inner + member.key.literal + ": "
                write(member.value, indent: indent, level: level + 1, into: &out)
                out += offset == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: indent, count: level) + "}"
        }
    }
}

// MARK: - 파서

private struct JSONParser {
    let bytes: [UInt8]
    var position = 0
    private let maxDepth = 256

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue(depth: 0)
        skipWhitespace()
        if position < bytes.count { throw error("값 뒤에 남은 내용이 있음") }
        return value
    }

    private func error(_ message: String, at offset: Int? = nil) -> JSONParseError {
        let target = min(offset ?? position, bytes.count)
        var line = 1
        var column = 1
        for byte in bytes[..<target] {
            if byte == 0x0A { line += 1; column = 1 } else { column += 1 }
        }
        return JSONParseError(message: message, line: line, column: column)
    }

    private mutating func skipWhitespace() {
        while position < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[position]) { position += 1 }
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        if depth > maxDepth { throw error("중첩이 너무 깊음") }
        skipWhitespace()
        guard position < bytes.count else { throw error("값이 필요한데 입력이 끝남") }
        switch bytes[position] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ word: String) throws {
        let literal = Array(word.utf8)
        guard bytes.count - position >= literal.count, Array(bytes[position..<(position + literal.count)]) == literal else {
            throw error("알 수 없는 값")
        }
        position += literal.count
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = position
        if position < bytes.count, bytes[position] == UInt8(ascii: "-") { position += 1 }
        let digitsStart = position
        while position < bytes.count, isNumberByte(bytes[position]) { position += 1 }
        guard position > digitsStart, bytes[digitsStart] != UInt8(ascii: "."), bytes[digitsStart] != UInt8(ascii: "e") else {
            throw error("알 수 없는 값", at: start)
        }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        guard Double(text) != nil else { throw error("올바르지 않은 숫자: \(text)", at: start) }
        return .number(text)
    }

    private func isNumberByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e")
            || byte == UInt8(ascii: "E") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        position += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
        while true {
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard position < bytes.count else { throw error("배열이 닫히지 않음") }
            if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
            if bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
            throw error("`,` 또는 `]`가 필요함")
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        position += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") { position += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw error("객체 키(문자열)가 필요함") }
            let key = try parseString()
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw error("`:`가 필요함") }
            position += 1
            let value = try parseValue(depth: depth + 1)
            members.append(JSONMember(key: key, value: value))
            skipWhitespace()
            guard position < bytes.count else { throw error("객체가 닫히지 않음") }
            if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
            if bytes[position] == UInt8(ascii: "}") { position += 1; return .object(members) }
            throw error("`,` 또는 `}`가 필요함")
        }
    }

    private mutating func parseString() throws -> JSONString {
        let start = position
        position += 1
        var scalars = String.UnicodeScalarView()
        var chunk: [UInt8] = []

        func flush() {
            if !chunk.isEmpty {
                scalars.append(contentsOf: String(decoding: chunk, as: UTF8.self).unicodeScalars)
                chunk.removeAll(keepingCapacity: true)
            }
        }

        while true {
            guard position < bytes.count else { throw error("문자열이 닫히지 않음", at: start) }
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                position += 1
                flush()
                let raw = String(decoding: bytes[start..<position], as: UTF8.self)
                return JSONString(value: String(scalars), raw: raw)
            }
            if byte < 0x20 { throw error("문자열 안의 제어 문자는 이스케이프해야 함") }
            if byte != UInt8(ascii: "\\") {
                chunk.append(byte)
                position += 1
                continue
            }
            flush()
            position += 1
            guard position < bytes.count else { throw error("문자열이 닫히지 않음", at: start) }
            let escape = bytes[position]
            position += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                let first = try parseHex4()
                if (0xD800...0xDBFF).contains(first) {
                    // 상위 서로게이트 뒤에 하위 서로게이트가 이어져야 한 글자가 된다. 짝이 안 맞으면 U+FFFD(원문은 raw로 보존).
                    if position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") {
                        let save = position
                        position += 2
                        let second = try parseHex4()
                        if (0xDC00...0xDFFF).contains(second) {
                            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                            scalars.append(Unicode.Scalar(combined) ?? "\u{FFFD}")
                        } else {
                            position = save
                            scalars.append("\u{FFFD}")
                        }
                    } else {
                        scalars.append("\u{FFFD}")
                    }
                } else {
                    scalars.append(Unicode.Scalar(first) ?? "\u{FFFD}")
                }
            default:
                throw error("알 수 없는 이스케이프 `\\\(String(UnicodeScalar(escape)))`", at: position - 1)
            }
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw error("`\\u` 뒤에 16진수 4자리가 필요함") }
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = hexValue(bytes[position]) else { throw error("`\\u` 뒤에 16진수 4자리가 필요함") }
            result = result << 4 | digit
            position += 1
        }
        return result
    }

    private func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: UInt32(byte - 0x30)
        case 0x41...0x46: UInt32(byte - 0x41 + 10)
        case 0x61...0x66: UInt32(byte - 0x61 + 10)
        default: nil
        }
    }
}
