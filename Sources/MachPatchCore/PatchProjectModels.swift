public struct PatchProject: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let projectName: String
    public let target: PatchTargetIdentity
    public let build: PatchBuildConfiguration
    public let runtimeControls: PatchRuntimeControlsConfiguration?
    public let patches: [MethodPatch]

    public init(
        formatVersion: Int = PatchProject.currentFormatVersion,
        projectName: String,
        target: PatchTargetIdentity,
        build: PatchBuildConfiguration,
        runtimeControls: PatchRuntimeControlsConfiguration? = nil,
        patches: [MethodPatch]
    ) {
        self.formatVersion = formatVersion
        self.projectName = projectName
        self.target = target
        self.build = build
        self.runtimeControls = runtimeControls
        self.patches = patches
    }
}

public struct PatchTargetIdentity: Codable, Equatable, Sendable {
    /// Host application or standalone-input identity.
    public let bundleIdentifier: String?
    public let executableName: String
    public let executableSHA256: String
    /// The image whose Objective-C metadata the patches were created from.
    public let selectedImage: PatchImageIdentity
    public let selectedSlice: PatchSelectedSlice
    public let minimumIOSVersion: String?

    public init(
        bundleIdentifier: String?,
        executableName: String,
        executableSHA256: String,
        selectedSlice: PatchSelectedSlice,
        minimumIOSVersion: String?
    ) {
        self.init(
            bundleIdentifier: bundleIdentifier,
            executableName: executableName,
            executableSHA256: executableSHA256,
            selectedImage: PatchImageIdentity(
                kind: .mainExecutable,
                relativePath: executableName,
                bundleIdentifier: bundleIdentifier,
                executableName: executableName,
                executableSHA256: executableSHA256
            ),
            selectedSlice: selectedSlice,
            minimumIOSVersion: minimumIOSVersion
        )
    }

    public init(
        bundleIdentifier: String?,
        executableName: String,
        executableSHA256: String,
        selectedImage: PatchImageIdentity,
        selectedSlice: PatchSelectedSlice,
        minimumIOSVersion: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.executableSHA256 = executableSHA256
        self.selectedImage = selectedImage
        self.selectedSlice = selectedSlice
        self.minimumIOSVersion = minimumIOSVersion
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case executableName
        case executableSHA256
        case selectedImage
        case selectedSlice
        case minimumIOSVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .bundleIdentifier
        )
        let executableName = try container.decode(String.self, forKey: .executableName)
        let executableSHA256 = try container.decode(String.self, forKey: .executableSHA256)
        self.init(
            bundleIdentifier: bundleIdentifier,
            executableName: executableName,
            executableSHA256: executableSHA256,
            selectedImage: try container.decodeIfPresent(
                PatchImageIdentity.self,
                forKey: .selectedImage
            )
                ?? PatchImageIdentity(
                    kind: .mainExecutable,
                    relativePath: executableName,
                    bundleIdentifier: bundleIdentifier,
                    executableName: executableName,
                    executableSHA256: executableSHA256
                ),
            selectedSlice: try container.decode(
                PatchSelectedSlice.self,
                forKey: .selectedSlice
            ),
            minimumIOSVersion: try container.decodeIfPresent(
                String.self,
                forKey: .minimumIOSVersion
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(executableName, forKey: .executableName)
        try container.encode(executableSHA256, forKey: .executableSHA256)
        try container.encode(selectedImage, forKey: .selectedImage)
        try container.encode(selectedSlice, forKey: .selectedSlice)
        try container.encodeIfPresent(minimumIOSVersion, forKey: .minimumIOSVersion)
    }
}

public struct PatchImageIdentity: Codable, Equatable, Sendable {
    public let kind: ResolvedImageKind
    public let relativePath: String
    public let bundleIdentifier: String?
    public let executableName: String
    public let executableSHA256: String

    public init(
        kind: ResolvedImageKind,
        relativePath: String,
        bundleIdentifier: String?,
        executableName: String,
        executableSHA256: String
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.executableSHA256 = executableSHA256
    }

    public init(image: ResolvedImage) {
        self.init(
            kind: image.kind,
            relativePath: image.relativePath,
            bundleIdentifier: image.bundleIdentifier,
            executableName: image.executableName,
            executableSHA256: image.sha256
        )
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
    public let advanced: PatchAdvancedConfiguration?
    public let runtimeControl: PatchRuntimeControlConfiguration?

    public init(
        id: String,
        enabled: Bool,
        className: String,
        selector: String,
        methodKind: ObjectiveCMethodKind,
        expectedTypeEncoding: String,
        action: PatchAction,
        advanced: PatchAdvancedConfiguration? = nil,
        runtimeControl: PatchRuntimeControlConfiguration? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.className = className
        self.selector = selector
        self.methodKind = methodKind
        self.expectedTypeEncoding = expectedTypeEncoding
        self.action = action
        self.advanced = advanced
        self.runtimeControl = runtimeControl
    }
}

public enum PatchAction: Equatable, Sendable {
    case returnBoolean(Bool)
    case returnSignedInteger(Int64)
    case returnUnsignedInteger(UInt64)
    case returnFloatingPoint(Double)
    case returnNil
    case returnClassNamed(String)
    case returnSelector(String)
    case returnString(String)
    case returnObject(PatchObjectValue)
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
        case .returnFloatingPoint: .returnFloatingPoint
        case .returnNil: .returnNil
        case .returnClassNamed: .returnClassNamed
        case .returnSelector: .returnSelector
        case .returnString: .returnString
        case .returnObject: .returnObject
        case .logInvocation: .logInvocation
        case .logArguments: .logArguments
        case .logOriginalReturnValue: .logOriginalReturnValue
        case .callOriginal: .callOriginal
        case .callOriginalAndReplace: .callOriginalAndReplace
        }
    }

    public var callsOriginal: Bool {
        switch self {
        case .returnBoolean, .returnSignedInteger, .returnUnsignedInteger, .returnFloatingPoint,
            .returnNil, .returnClassNamed, .returnSelector, .returnString, .returnObject:
            false
        case .logInvocation, .logArguments, .logOriginalReturnValue, .callOriginal,
            .callOriginalAndReplace:
            true
        }
    }
}

public enum PatchActionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case returnBoolean
    case returnSignedInteger
    case returnUnsignedInteger
    case returnFloatingPoint
    case returnNil
    case returnClassNamed
    case returnSelector
    case returnString
    case returnObject
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
    case floatingPoint(Double)
    case nilValue
    case classNamed(String)
    case selector(String)
    case string(String)

    public var kind: PatchReturnValueKind {
        switch self {
        case .boolean: .boolean
        case .signedInteger: .signedInteger
        case .unsignedInteger: .unsignedInteger
        case .floatingPoint: .floatingPoint
        case .nilValue: .nilValue
        case .classNamed: .classNamed
        case .selector: .selector
        case .string: .string
        }
    }
}

public enum PatchReturnValueKind: String, Codable, Equatable, Sendable {
    case boolean
    case signedInteger
    case unsignedInteger
    case floatingPoint
    case nilValue = "nil"
    case classNamed
    case selector
    case string
}

extension PatchAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case replacement
        case object
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
        case .returnFloatingPoint:
            self = .returnFloatingPoint(try container.decode(Double.self, forKey: .value))
        case .returnNil:
            self = .returnNil
        case .returnClassNamed:
            self = .returnClassNamed(try container.decode(String.self, forKey: .value))
        case .returnSelector:
            self = .returnSelector(try container.decode(String.self, forKey: .value))
        case .returnString:
            self = .returnString(try container.decode(String.self, forKey: .value))
        case .returnObject:
            self = .returnObject(try container.decode(PatchObjectValue.self, forKey: .object))
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
        case .returnFloatingPoint(let value):
            try container.encode(value, forKey: .value)
        case .returnClassNamed(let value):
            try container.encode(value, forKey: .value)
        case .returnSelector(let value):
            try container.encode(value, forKey: .value)
        case .returnString(let value):
            try container.encode(value, forKey: .value)
        case .returnObject(let object):
            try container.encode(object, forKey: .object)
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
        case .floatingPoint:
            self = .floatingPoint(try container.decode(Double.self, forKey: .value))
        case .nilValue:
            self = .nilValue
        case .classNamed:
            self = .classNamed(try container.decode(String.self, forKey: .value))
        case .selector:
            self = .selector(try container.decode(String.self, forKey: .value))
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
        case .floatingPoint(let value):
            try container.encode(value, forKey: .value)
        case .classNamed(let value):
            try container.encode(value, forKey: .value)
        case .selector(let value):
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(value, forKey: .value)
        case .nilValue:
            break
        }
    }
}
