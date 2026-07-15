import Foundation

public struct ObjectiveCMethodSignature: Codable, Equatable, Sendable {
    public let rawEncoding: String
    public let frameSize: Int?
    public let returnType: ObjectiveCType
    public let arguments: [ObjectiveCType]

    public init(
        rawEncoding: String,
        frameSize: Int?,
        returnType: ObjectiveCType,
        arguments: [ObjectiveCType]
    ) {
        self.rawEncoding = rawEncoding
        self.frameSize = frameSize
        self.returnType = returnType
        self.arguments = arguments
    }

    public var explicitArguments: [ObjectiveCType] {
        Array(arguments.dropFirst(min(arguments.count, 2)))
    }
}

public struct ObjectiveCType: Codable, Equatable, Sendable {
    public let encoding: String
    public let kind: ObjectiveCTypeKind
    public let qualifiers: [ObjectiveCTypeQualifier]
    public let annotation: String?
    public let count: Int?
    public let children: [ObjectiveCType]

    public init(
        encoding: String,
        kind: ObjectiveCTypeKind,
        qualifiers: [ObjectiveCTypeQualifier] = [],
        annotation: String? = nil,
        count: Int? = nil,
        children: [ObjectiveCType] = []
    ) {
        self.encoding = encoding
        self.kind = kind
        self.qualifiers = qualifiers
        self.annotation = annotation
        self.count = count
        self.children = children
    }
}

public enum ObjectiveCTypeKind: String, Codable, Equatable, Hashable, Sendable {
    case void
    case boolean
    case signedChar
    case unsignedChar
    case signedShort
    case unsignedShort
    case signedInt
    case unsignedInt
    case signedLong
    case unsignedLong
    case signedLongLong
    case unsignedLongLong
    case float
    case double
    case longDouble
    case object
    case block
    case classObject
    case selector
    case cString
    case pointer
    case array
    case structure
    case union
    case bitField
    case unknown

    public var isSignedInteger: Bool {
        switch self {
        case .signedChar, .signedShort, .signedInt, .signedLong, .signedLongLong:
            true
        default:
            false
        }
    }

    public var isUnsignedInteger: Bool {
        switch self {
        case .unsignedChar, .unsignedShort, .unsignedInt, .unsignedLong, .unsignedLongLong:
            true
        default:
            false
        }
    }
}

public enum ObjectiveCTypeQualifier: String, Codable, Equatable, Sendable {
    case constant = "r"
    case input = "n"
    case inputOutput = "N"
    case output = "o"
    case bycopy = "O"
    case byref = "R"
    case oneway = "V"
    case atomic = "A"
}

public enum ObjectiveCTypeEncodingDecoder {
    public static func decodeMethodSignature(
        _ encoding: String
    ) throws -> ObjectiveCMethodSignature {
        var parser = ObjectiveCEncodingParser(encoding)
        return try parser.parseMethodSignature()
    }
}

public struct ObjectiveCTypeEncodingError: Error, Equatable, LocalizedError, Sendable {
    public let offset: Int
    public let reason: String

    public init(offset: Int, reason: String) {
        self.offset = offset
        self.reason = reason
    }

    public var errorDescription: String? {
        "Invalid Objective-C type encoding at character \(offset): \(reason)"
    }
}

private struct ObjectiveCEncodingParser {
    private let source: String
    private let characters: [Character]
    private var index = 0

    init(_ source: String) {
        self.source = source
        characters = Array(source)
    }

    mutating func parseMethodSignature() throws -> ObjectiveCMethodSignature {
        skipWhitespace()
        guard !isAtEnd else { throw error("encoding is empty") }

        let returnType = try parseType()
        let frameSize = try parseLayoutNumber()
        var arguments: [ObjectiveCType] = []

        while true {
            skipWhitespace()
            guard !isAtEnd else { break }
            arguments.append(try parseType())
            _ = try parseLayoutNumber()
        }

        return ObjectiveCMethodSignature(
            rawEncoding: source,
            frameSize: frameSize,
            returnType: returnType,
            arguments: arguments
        )
    }

    private mutating func parseType() throws -> ObjectiveCType {
        skipWhitespace()
        let start = index
        var qualifiers: [ObjectiveCTypeQualifier] = []
        while let character = current,
            let qualifier = ObjectiveCTypeQualifier(rawValue: String(character))
        {
            qualifiers.append(qualifier)
            advance()
        }
        guard let character = current else { throw error("a type was expected") }

        let components:
            (
                kind: ObjectiveCTypeKind,
                annotation: String?,
                count: Int?,
                children: [ObjectiveCType]
            )

        switch character {
        case "v":
            advance()
            components = (.void, nil, nil, [])
        case "B":
            advance()
            components = (.boolean, nil, nil, [])
        case "c":
            advance()
            components = (.signedChar, nil, nil, [])
        case "C":
            advance()
            components = (.unsignedChar, nil, nil, [])
        case "s":
            advance()
            components = (.signedShort, nil, nil, [])
        case "S":
            advance()
            components = (.unsignedShort, nil, nil, [])
        case "i":
            advance()
            components = (.signedInt, nil, nil, [])
        case "I":
            advance()
            components = (.unsignedInt, nil, nil, [])
        case "l":
            advance()
            components = (.signedLong, nil, nil, [])
        case "L":
            advance()
            components = (.unsignedLong, nil, nil, [])
        case "q":
            advance()
            components = (.signedLongLong, nil, nil, [])
        case "Q":
            advance()
            components = (.unsignedLongLong, nil, nil, [])
        case "f":
            advance()
            components = (.float, nil, nil, [])
        case "d":
            advance()
            components = (.double, nil, nil, [])
        case "D":
            advance()
            components = (.longDouble, nil, nil, [])
        case "@":
            advance()
            if current == "?" {
                advance()
                components = (.block, nil, nil, [])
            } else if current == "\"" {
                components = (.object, try parseQuotedString(), nil, [])
            } else {
                components = (.object, nil, nil, [])
            }
        case "#":
            advance()
            components = (.classObject, nil, nil, [])
        case ":":
            advance()
            components = (.selector, nil, nil, [])
        case "*":
            advance()
            components = (.cString, nil, nil, [])
        case "^":
            advance()
            components = (.pointer, nil, nil, [try parseType()])
        case "[":
            components = try parseArray()
        case "{":
            components = try parseComposite(
                opening: "{",
                closing: "}",
                kind: .structure
            )
        case "(":
            components = try parseComposite(
                opening: "(",
                closing: ")",
                kind: .union
            )
        case "b":
            advance()
            components = (.bitField, nil, try parseRequiredUnsignedNumber("bit-field width"), [])
        case "?":
            advance()
            components = (.unknown, nil, nil, [])
        default:
            throw error("unsupported type code '\(character)'")
        }

        return ObjectiveCType(
            encoding: String(characters[start..<index]),
            kind: components.kind,
            qualifiers: qualifiers,
            annotation: components.annotation,
            count: components.count,
            children: components.children
        )
    }

    private mutating func parseArray() throws -> (
        ObjectiveCTypeKind, String?, Int?, [ObjectiveCType]
    ) {
        advance()
        let count = try parseRequiredUnsignedNumber("array count")
        let child = try parseType()
        guard current == "]" else { throw error("array is missing closing ']'") }
        advance()
        return (.array, nil, count, [child])
    }

    private mutating func parseComposite(
        opening: Character,
        closing: Character,
        kind: ObjectiveCTypeKind
    ) throws -> (ObjectiveCTypeKind, String?, Int?, [ObjectiveCType]) {
        precondition(current == opening)
        advance()
        let nameStart = index
        while let character = current, character != "=", character != closing {
            advance()
        }
        guard current != nil else {
            throw error("\(kind.rawValue) is missing closing '\(closing)'")
        }
        let name = String(characters[nameStart..<index])
        var children: [ObjectiveCType] = []

        if current == "=" {
            advance()
            while current != closing {
                guard current != nil else {
                    throw error("\(kind.rawValue) is missing closing '\(closing)'")
                }
                if current == "\"" { _ = try parseQuotedString() }
                guard current != closing else { break }
                children.append(try parseType())
            }
        }

        guard current == closing else {
            throw error("\(kind.rawValue) is missing closing '\(closing)'")
        }
        advance()
        return (kind, name.isEmpty ? nil : name, nil, children)
    }

    private mutating func parseQuotedString() throws -> String {
        guard current == "\"" else { throw error("a quoted annotation was expected") }
        advance()
        var result = ""
        while let character = current {
            if character == "\"" {
                advance()
                return result
            }
            if character == "\\" {
                advance()
                guard let escaped = current else {
                    throw error("quoted annotation ends with an escape")
                }
                result.append(escaped)
                advance()
            } else {
                result.append(character)
                advance()
            }
        }
        throw error("quoted annotation is missing its closing quote")
    }

    private mutating func parseLayoutNumber() throws -> Int? {
        skipWhitespace()
        let start = index
        if current == "+" || current == "-" { advance() }
        let digitStart = index
        while current?.isNumber == true { advance() }
        guard index > digitStart else {
            index = start
            return nil
        }
        let value = String(characters[start..<index])
        guard let number = Int(value) else { throw error("layout value is out of range") }
        return number
    }

    private mutating func parseRequiredUnsignedNumber(_ label: String) throws -> Int {
        let start = index
        while current?.isNumber == true { advance() }
        guard index > start else { throw error("\(label) is missing") }
        let value = String(characters[start..<index])
        guard let number = Int(value) else { throw error("\(label) is out of range") }
        return number
    }

    private mutating func skipWhitespace() {
        while current?.isWhitespace == true { advance() }
    }

    private var current: Character? {
        index < characters.count ? characters[index] : nil
    }

    private var isAtEnd: Bool { index == characters.count }

    private mutating func advance() {
        index += 1
    }

    private func error(_ reason: String) -> ObjectiveCTypeEncodingError {
        ObjectiveCTypeEncodingError(offset: index, reason: reason)
    }
}
