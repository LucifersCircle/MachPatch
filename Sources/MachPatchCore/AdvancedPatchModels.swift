import Foundation

public struct PatchAdvancedConfiguration: Codable, Equatable, Sendable {
    public let argumentReplacements: [PatchArgumentReplacement]
    public let beforeEffects: [PatchEffect]
    public let afterEffects: [PatchEffect]
    public let conditionalReturn: PatchConditionalReturn?
    public let invocationCounter: PatchInvocationCounter?

    public init(
        argumentReplacements: [PatchArgumentReplacement] = [],
        beforeEffects: [PatchEffect] = [],
        afterEffects: [PatchEffect] = [],
        conditionalReturn: PatchConditionalReturn? = nil,
        invocationCounter: PatchInvocationCounter? = nil
    ) {
        self.argumentReplacements = argumentReplacements
        self.beforeEffects = beforeEffects
        self.afterEffects = afterEffects
        self.conditionalReturn = conditionalReturn
        self.invocationCounter = invocationCounter
    }

    public var isEmpty: Bool {
        argumentReplacements.isEmpty && beforeEffects.isEmpty && afterEffects.isEmpty
            && conditionalReturn == nil && invocationCounter == nil
    }
}

public struct PatchArgumentReplacement: Codable, Equatable, Sendable {
    public let argumentIndex: Int
    public let value: PatchValue

    public init(argumentIndex: Int, value: PatchValue) {
        self.argumentIndex = argumentIndex
        self.value = value
    }
}

public struct PatchConditionalReturn: Codable, Equatable, Sendable {
    public let condition: PatchCondition
    public let replacement: PatchReturnValue

    public init(condition: PatchCondition, replacement: PatchReturnValue) {
        self.condition = condition
        self.replacement = replacement
    }
}

public struct PatchCondition: Codable, Equatable, Sendable {
    public let source: PatchConditionSource
    public let comparison: PatchComparison
    public let value: PatchValue

    public init(
        source: PatchConditionSource,
        comparison: PatchComparison,
        value: PatchValue
    ) {
        self.source = source
        self.comparison = comparison
        self.value = value
    }
}

public enum PatchConditionSource: Equatable, Sendable {
    case argument(Int)
    case invocationCount
}

public enum PatchComparison: String, Codable, CaseIterable, Equatable, Sendable {
    case equal
    case notEqual
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
}

public struct PatchInvocationCounter: Codable, Equatable, Sendable {
    public let logEachInvocation: Bool

    public init(logEachInvocation: Bool = true) {
        self.logEachInvocation = logEachInvocation
    }
}

public enum PatchEffect: Equatable, Sendable {
    case showAlert(PatchAlert)
    case customObjectiveC(PatchCustomObjectiveC)
}

public struct PatchAlert: Codable, Equatable, Sendable {
    public let title: String
    public let message: String
    public let buttonTitle: String

    public init(title: String, message: String, buttonTitle: String = "OK") {
        self.title = title
        self.message = message
        self.buttonTitle = buttonTitle
    }
}

public struct PatchCustomObjectiveC: Codable, Equatable, Sendable {
    public static let maximumUTF8ByteCount = 16 * 1_024

    public let source: String

    public init(source: String) {
        self.source = source
    }
}

public enum PatchValue: Equatable, Sendable {
    case boolean(Bool)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case nilValue
    case string(String)
    case selector(String)
    case classNamed(String)

    public var kind: PatchValueKind {
        switch self {
        case .boolean: .boolean
        case .signedInteger: .signedInteger
        case .unsignedInteger: .unsignedInteger
        case .nilValue: .nilValue
        case .string: .string
        case .selector: .selector
        case .classNamed: .classNamed
        }
    }
}

public enum PatchValueKind: String, Codable, CaseIterable, Equatable, Sendable {
    case boolean
    case signedInteger
    case unsignedInteger
    case nilValue = "nil"
    case string
    case selector
    case classNamed
}

public enum PatchObjectValue: Equatable, Sendable {
    case numberBoolean(Bool)
    case numberSignedInteger(Int64)
    case numberUnsignedInteger(UInt64)
    case arrayOfStrings([String])
    case dictionaryOfStrings([String: String])
    case url(String)

    public var kind: PatchObjectValueKind {
        switch self {
        case .numberBoolean: .numberBoolean
        case .numberSignedInteger: .numberSignedInteger
        case .numberUnsignedInteger: .numberUnsignedInteger
        case .arrayOfStrings: .arrayOfStrings
        case .dictionaryOfStrings: .dictionaryOfStrings
        case .url: .url
        }
    }
}

public enum PatchObjectValueKind: String, Codable, CaseIterable, Equatable, Sendable {
    case numberBoolean
    case numberSignedInteger
    case numberUnsignedInteger
    case arrayOfStrings
    case dictionaryOfStrings
    case url
}

extension PatchConditionSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case argumentIndex
    }

    private enum Kind: String, Codable {
        case argument
        case invocationCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .argument:
            self = .argument(try container.decode(Int.self, forKey: .argumentIndex))
        case .invocationCount:
            self = .invocationCount
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .argument(let index):
            try container.encode(Kind.argument, forKey: .kind)
            try container.encode(index, forKey: .argumentIndex)
        case .invocationCount:
            try container.encode(Kind.invocationCount, forKey: .kind)
        }
    }
}

extension PatchEffect: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case alert
        case customObjectiveC
    }

    private enum Kind: String, Codable {
        case showAlert
        case customObjectiveC
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .showAlert:
            self = .showAlert(try container.decode(PatchAlert.self, forKey: .alert))
        case .customObjectiveC:
            self = .customObjectiveC(
                try container.decode(PatchCustomObjectiveC.self, forKey: .customObjectiveC)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .showAlert(let alert):
            try container.encode(Kind.showAlert, forKey: .kind)
            try container.encode(alert, forKey: .alert)
        case .customObjectiveC(let customObjectiveC):
            try container.encode(Kind.customObjectiveC, forKey: .kind)
            try container.encode(customObjectiveC, forKey: .customObjectiveC)
        }
    }
}

extension PatchValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PatchValueKind.self, forKey: .kind) {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .signedInteger:
            self = .signedInteger(try container.decode(Int64.self, forKey: .value))
        case .unsignedInteger:
            self = .unsignedInteger(try container.decode(UInt64.self, forKey: .value))
        case .nilValue:
            self = .nilValue
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .selector:
            self = .selector(try container.decode(String.self, forKey: .value))
        case .classNamed:
            self = .classNamed(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .boolean(let value): try container.encode(value, forKey: .value)
        case .signedInteger(let value): try container.encode(value, forKey: .value)
        case .unsignedInteger(let value): try container.encode(value, forKey: .value)
        case .string(let value): try container.encode(value, forKey: .value)
        case .selector(let value): try container.encode(value, forKey: .value)
        case .classNamed(let value): try container.encode(value, forKey: .value)
        case .nilValue: break
        }
    }
}

extension PatchObjectValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PatchObjectValueKind.self, forKey: .kind) {
        case .numberBoolean:
            self = .numberBoolean(try container.decode(Bool.self, forKey: .value))
        case .numberSignedInteger:
            self = .numberSignedInteger(try container.decode(Int64.self, forKey: .value))
        case .numberUnsignedInteger:
            self = .numberUnsignedInteger(try container.decode(UInt64.self, forKey: .value))
        case .arrayOfStrings:
            self = .arrayOfStrings(try container.decode([String].self, forKey: .value))
        case .dictionaryOfStrings:
            self = .dictionaryOfStrings(
                try container.decode([String: String].self, forKey: .value)
            )
        case .url:
            self = .url(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .numberBoolean(let value): try container.encode(value, forKey: .value)
        case .numberSignedInteger(let value): try container.encode(value, forKey: .value)
        case .numberUnsignedInteger(let value): try container.encode(value, forKey: .value)
        case .arrayOfStrings(let value): try container.encode(value, forKey: .value)
        case .dictionaryOfStrings(let value): try container.encode(value, forKey: .value)
        case .url(let value): try container.encode(value, forKey: .value)
        }
    }
}
