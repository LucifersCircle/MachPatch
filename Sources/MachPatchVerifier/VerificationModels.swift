import Foundation
import MachPatchCore

public enum VerificationCheckStatus: String, Codable, Equatable, Sendable {
    case passed
    case warning
    case failed
}

public enum DylibVerificationResult: String, Codable, Equatable, Sendable {
    case readyForLiveContainerTesting
    case blocked
}

public enum VerificationCheckCode: String, Codable, Equatable, Sendable {
    case fileType
    case architecture
    case lipoAgreement
    case platform
    case deploymentTarget
    case installName
    case dependency
    case unresolvedSymbols
    case targetCompatibility
    case forbiddenFilesystemPath
}

public struct VerificationCheck: Codable, Equatable, Sendable {
    public let code: VerificationCheckCode
    public let status: VerificationCheckStatus
    public let message: String
    public let sliceIndex: Int?
    public let evidence: [String]

    public init(
        code: VerificationCheckCode,
        status: VerificationCheckStatus,
        message: String,
        sliceIndex: Int? = nil,
        evidence: [String] = []
    ) {
        self.code = code
        self.status = status
        self.message = message
        self.sliceIndex = sliceIndex
        self.evidence = evidence
    }
}

public enum DependencyClassification: String, Codable, Equatable, Sendable {
    case appleSystem
    case includedAdjacent
    case forbiddenJailbreak
    case unsupportedExternal
}

public struct DependencyAssessment: Codable, Equatable, Sendable {
    public let sliceIndex: Int
    public let library: LinkedLibrary
    public let classification: DependencyClassification
    public let resolvedPath: String?

    public init(
        sliceIndex: Int,
        library: LinkedLibrary,
        classification: DependencyClassification,
        resolvedPath: String?
    ) {
        self.sliceIndex = sliceIndex
        self.library = library
        self.classification = classification
        self.resolvedPath = resolvedPath
    }
}

public enum UnresolvedSymbolClassification: String, Codable, Equatable, Sendable {
    case expectedAppleRuntime
    case expectedAppleFramework
    case unexpectedExternal
}

public struct UnresolvedSymbol: Codable, Equatable, Sendable {
    public let architecture: String?
    public let name: String
    public let provider: String?
    public let classification: UnresolvedSymbolClassification

    public init(
        architecture: String?,
        name: String,
        provider: String?,
        classification: UnresolvedSymbolClassification
    ) {
        self.architecture = architecture
        self.name = name
        self.provider = provider
        self.classification = classification
    }
}

public struct ForbiddenPathFinding: Codable, Equatable, Sendable {
    public let marker: String
    public let value: String

    public init(marker: String, value: String) {
        self.marker = marker
        self.value = value
    }
}

public struct VerificationCommandInvocation: Codable, Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public struct VerificationCommandExecution: Codable, Equatable, Sendable {
    public let invocation: VerificationCommandInvocation
    public let standardOutput: String
    public let standardError: String
    public let terminationStatus: Int32
    public let durationMilliseconds: UInt64

    public init(
        invocation: VerificationCommandInvocation,
        standardOutput: String,
        standardError: String,
        terminationStatus: Int32,
        durationMilliseconds: UInt64
    ) {
        self.invocation = invocation
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct VerificationTools: Codable, Equatable, Sendable {
    public let lipoPath: String
    public let nmPath: String

    public init(lipoPath: String, nmPath: String) {
        self.lipoPath = lipoPath
        self.nmPath = nmPath
    }
}

public struct DylibVerificationReport: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let dylibPath: String
    public let target: ResolvedTarget?
    public let slices: [MachOSlice]
    public let targetSlices: [MachOSlice]
    public let lipoArchitectures: [String]
    public let dependencies: [DependencyAssessment]
    public let unresolvedSymbols: [UnresolvedSymbol]
    public let forbiddenPaths: [ForbiddenPathFinding]
    public let checks: [VerificationCheck]
    public let toolExecutions: [VerificationCommandExecution]
    public let result: DylibVerificationResult

    public init(
        formatVersion: Int = DylibVerificationReport.currentFormatVersion,
        dylibPath: String,
        target: ResolvedTarget?,
        slices: [MachOSlice],
        targetSlices: [MachOSlice],
        lipoArchitectures: [String],
        dependencies: [DependencyAssessment],
        unresolvedSymbols: [UnresolvedSymbol],
        forbiddenPaths: [ForbiddenPathFinding],
        checks: [VerificationCheck],
        toolExecutions: [VerificationCommandExecution]
    ) {
        self.formatVersion = formatVersion
        self.dylibPath = dylibPath
        self.target = target
        self.slices = slices
        self.targetSlices = targetSlices
        self.lipoArchitectures = lipoArchitectures
        self.dependencies = dependencies
        self.unresolvedSymbols = unresolvedSymbols
        self.forbiddenPaths = forbiddenPaths
        self.checks = checks
        self.toolExecutions = toolExecutions
        result =
            checks.contains { $0.status == .failed }
            ? .blocked : .readyForLiveContainerTesting
    }

    public var isReadyForLiveContainerTesting: Bool {
        result == .readyForLiveContainerTesting
    }

    public var blockingFailures: [VerificationCheck] {
        checks.filter { $0.status == .failed }
    }
}
