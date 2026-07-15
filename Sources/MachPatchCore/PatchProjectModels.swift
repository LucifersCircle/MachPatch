public struct PatchProject: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let projectName: String
    public let target: PatchTargetIdentity
    public let build: PatchBuildConfiguration
    public let patches: [MethodPatch]

    public init(
        formatVersion: Int = PatchProject.currentFormatVersion,
        projectName: String,
        target: PatchTargetIdentity,
        build: PatchBuildConfiguration,
        patches: [MethodPatch]
    ) {
        self.formatVersion = formatVersion
        self.projectName = projectName
        self.target = target
        self.build = build
        self.patches = patches
    }
}

public struct PatchTargetIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let executableName: String
    public let executableSHA256: String
    public let selectedSlice: PatchSelectedSlice
    public let minimumIOSVersion: String?

    public init(
        bundleIdentifier: String?,
        executableName: String,
        executableSHA256: String,
        selectedSlice: PatchSelectedSlice,
        minimumIOSVersion: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.executableSHA256 = executableSHA256
        self.selectedSlice = selectedSlice
        self.minimumIOSVersion = minimumIOSVersion
    }
}

public struct PatchSelectedSlice: Codable, Equatable, Sendable {
    public let architecture: MachOArchitecture
    public let cpuSubtype: Int32

    public init(architecture: MachOArchitecture, cpuSubtype: Int32) {
        self.architecture = architecture
        self.cpuSubtype = cpuSubtype
    }
}

public struct PatchBuildConfiguration: Codable, Equatable, Sendable {
    public let architectureMode: PatchArchitectureMode
    public let minimumIOSVersion: String
    public let outputName: String
    public let enableARC: Bool

    public init(
        architectureMode: PatchArchitectureMode,
        minimumIOSVersion: String,
        outputName: String,
        enableARC: Bool
    ) {
        self.architectureMode = architectureMode
        self.minimumIOSVersion = minimumIOSVersion
        self.outputName = outputName
        self.enableARC = enableARC
    }
}

public enum PatchArchitectureMode: String, Codable, Equatable, Sendable {
    case automatic
    case arm64
    case arm64e
    case universal
}

public struct MethodPatch: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let enabled: Bool
    public let className: String
    public let selector: String
    public let methodKind: ObjectiveCMethodKind
    public let expectedTypeEncoding: String
    public let action: PatchAction

    public init(
        id: String,
        enabled: Bool,
        className: String,
        selector: String,
        methodKind: ObjectiveCMethodKind,
        expectedTypeEncoding: String,
        action: PatchAction
    ) {
        self.id = id
        self.enabled = enabled
        self.className = className
        self.selector = selector
        self.methodKind = methodKind
        self.expectedTypeEncoding = expectedTypeEncoding
        self.action = action
    }
}

public enum PatchAction: Equatable, Sendable {
    case returnBoolean(Bool)
    case returnSignedInteger(Int64)
    case returnUnsignedInteger(UInt64)
    case returnNil
    case returnString(String)
    case logInvocation
    case logArguments
    case logOriginalReturnValue
    case callOriginal
    case callOriginalAndReplace(PatchReturnValue)

    public var kind: PatchActionKind {
        switch self {
        case .returnBoolean: .returnBoolean
        case .returnSignedInteger: .returnSignedInteger
        case .returnUnsignedInteger: .returnUnsignedInteger
        case .returnNil: .returnNil
        case .returnString: .returnString
        case .logInvocation: .logInvocation
        case .logArguments: .logArguments
        case .logOriginalReturnValue: .logOriginalReturnValue
        case .callOriginal: .callOriginal
        case .callOriginalAndReplace: .callOriginalAndReplace
        }
    }
}

public enum PatchActionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case returnBoolean
    case returnSignedInteger
    case returnUnsignedInteger
    case returnNil
    case returnString
    case logInvocation
    case logArguments
    case logOriginalReturnValue
    case callOriginal
    case callOriginalAndReplace
}

public enum PatchReturnValue: Equatable, Sendable {
    case boolean(Bool)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case nilValue
    case string(String)

    public var kind: PatchReturnValueKind {
        switch self {
        case .boolean: .boolean
        case .signedInteger: .signedInteger
        case .unsignedInteger: .unsignedInteger
        case .nilValue: .nilValue
        case .string: .string
        }
    }
}

public enum PatchReturnValueKind: String, Codable, Equatable, Sendable {
    case boolean
    case signedInteger
    case unsignedInteger
    case nilValue = "nil"
    case string
}

extension PatchAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case replacement
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(PatchActionKind.self, forKey: .kind)
        switch kind {
        case .returnBoolean:
            self = .returnBoolean(try container.decode(Bool.self, forKey: .value))
        case .returnSignedInteger:
            self = .returnSignedInteger(try container.decode(Int64.self, forKey: .value))
        case .returnUnsignedInteger:
            self = .returnUnsignedInteger(try container.decode(UInt64.self, forKey: .value))
        case .returnNil:
            self = .returnNil
        case .returnString:
            self = .returnString(try container.decode(String.self, forKey: .value))
        case .logInvocation:
            self = .logInvocation
        case .logArguments:
            self = .logArguments
        case .logOriginalReturnValue:
            self = .logOriginalReturnValue
        case .callOriginal:
            self = .callOriginal
        case .callOriginalAndReplace:
            self = .callOriginalAndReplace(
                try container.decode(PatchReturnValue.self, forKey: .replacement)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .returnBoolean(let value):
            try container.encode(value, forKey: .value)
        case .returnSignedInteger(let value):
            try container.encode(value, forKey: .value)
        case .returnUnsignedInteger(let value):
            try container.encode(value, forKey: .value)
        case .returnString(let value):
            try container.encode(value, forKey: .value)
        case .callOriginalAndReplace(let replacement):
            try container.encode(replacement, forKey: .replacement)
        case .returnNil, .logInvocation, .logArguments, .logOriginalReturnValue, .callOriginal:
            break
        }
    }
}

extension PatchReturnValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(PatchReturnValueKind.self, forKey: .kind)
        switch kind {
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
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .boolean(let value):
            try container.encode(value, forKey: .value)
        case .signedInteger(let value):
            try container.encode(value, forKey: .value)
        case .unsignedInteger(let value):
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(value, forKey: .value)
        case .nilValue:
            break
        }
    }
}
