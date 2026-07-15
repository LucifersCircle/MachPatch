import MachPatchCore

public enum BuildSliceArchitecture: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case arm64
    case arm64e

    public var clangName: String { rawValue }

    public var machOArchitecture: MachOArchitecture {
        switch self {
        case .arm64: .arm64
        case .arm64e: .arm64e
        }
    }
}

public enum PatchBuildOutputArchitecture: String, Codable, Equatable, Sendable {
    case arm64
    case arm64e
    case universal
}

public enum Arm64eABIGeneration: String, Codable, Equatable, Sendable {
    case legacy
    case versioned
    case unknown
}

public struct Arm64eABI: Codable, Equatable, Sendable {
    public let generation: Arm64eABIGeneration
    public let pointerAuthenticationVersion: UInt8?

    public init(
        generation: Arm64eABIGeneration,
        pointerAuthenticationVersion: UInt8?
    ) {
        self.generation = generation
        self.pointerAuthenticationVersion = pointerAuthenticationVersion
    }
}

public struct BuildArchitectureResolution: Codable, Equatable, Sendable {
    public let requestedMode: PatchArchitectureMode
    public let outputArchitecture: PatchBuildOutputArchitecture
    public let slices: [BuildSliceArchitecture]
    public let targetArchitecture: MachOArchitecture
    public let targetCPUSubtype: Int32
    public let targetArm64eABI: Arm64eABI?
    public let reason: String

    public init(
        requestedMode: PatchArchitectureMode,
        outputArchitecture: PatchBuildOutputArchitecture,
        slices: [BuildSliceArchitecture],
        targetArchitecture: MachOArchitecture,
        targetCPUSubtype: Int32,
        targetArm64eABI: Arm64eABI?,
        reason: String
    ) {
        self.requestedMode = requestedMode
        self.outputArchitecture = outputArchitecture
        self.slices = slices
        self.targetArchitecture = targetArchitecture
        self.targetCPUSubtype = targetCPUSubtype
        self.targetArm64eABI = targetArm64eABI
        self.reason = reason
    }
}

public struct TargetArchitectureSliceAssessment: Codable, Equatable, Sendable {
    public let index: Int
    public let architecture: MachOArchitecture
    public let cpuSubtype: Int32
    public let cpuSubtypeBase: UInt32
    public let cpuSubtypeCapabilities: UInt32
    public let platform: MachOPlatform
    public let arm64eABI: Arm64eABI?
    public let supportedForPatching: Bool
    public let diagnostic: String

    public init(
        index: Int,
        architecture: MachOArchitecture,
        cpuSubtype: Int32,
        cpuSubtypeBase: UInt32,
        cpuSubtypeCapabilities: UInt32,
        platform: MachOPlatform,
        arm64eABI: Arm64eABI?,
        supportedForPatching: Bool,
        diagnostic: String
    ) {
        self.index = index
        self.architecture = architecture
        self.cpuSubtype = cpuSubtype
        self.cpuSubtypeBase = cpuSubtypeBase
        self.cpuSubtypeCapabilities = cpuSubtypeCapabilities
        self.platform = platform
        self.arm64eABI = arm64eABI
        self.supportedForPatching = supportedForPatching
        self.diagnostic = diagnostic
    }
}

public struct TargetArchitectureReport: Codable, Equatable, Sendable {
    public let slices: [TargetArchitectureSliceAssessment]
    public let availableModes: [PatchArchitectureMode]
    public let automaticRecommendation: PatchArchitectureMode?
    public let automaticReason: String

    public init(
        slices: [TargetArchitectureSliceAssessment],
        availableModes: [PatchArchitectureMode],
        automaticRecommendation: PatchArchitectureMode?,
        automaticReason: String
    ) {
        self.slices = slices
        self.availableModes = availableModes
        self.automaticRecommendation = automaticRecommendation
        self.automaticReason = automaticReason
    }
}
