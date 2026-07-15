import Foundation
import MachPatchCore

public struct BuildCommandInvocation: Codable, Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }

    public var displayString: String {
        ([executablePath] + arguments).map(Self.quoteForDisplay).joined(separator: " ")
    }

    private static func quoteForDisplay(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._/:=@,+")
        )
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public struct BuildCommandExecution: Codable, Equatable, Sendable {
    public let invocation: BuildCommandInvocation
    public let standardOutput: String
    public let standardError: String
    public let terminationStatus: Int32
    public let durationMilliseconds: UInt64

    public init(
        invocation: BuildCommandInvocation,
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

public struct AppleToolchain: Codable, Equatable, Sendable {
    public let developerDirectory: String
    public let xcodeVersion: String
    public let clangPath: String
    public let clangVersion: String
    public let lipoPath: String
    public let nmPath: String
    public let sdkPath: String
    public let sdkVersion: String

    public init(
        developerDirectory: String,
        xcodeVersion: String,
        clangPath: String,
        clangVersion: String,
        lipoPath: String,
        nmPath: String,
        sdkPath: String,
        sdkVersion: String
    ) {
        self.developerDirectory = developerDirectory
        self.xcodeVersion = xcodeVersion
        self.clangPath = clangPath
        self.clangVersion = clangVersion
        self.lipoPath = lipoPath
        self.nmPath = nmPath
        self.sdkPath = sdkPath
        self.sdkVersion = sdkVersion
    }
}

public struct PatchBuildRecord: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 2

    public let formatVersion: Int
    public let projectName: String
    public let architecture: PatchBuildOutputArchitecture
    public let minimumIOSVersion: String
    public let installName: String
    public let sourcePath: String
    public let outputPath: String
    public let recordPath: String
    public let toolchain: AppleToolchain
    public let architectureResolution: BuildArchitectureResolution
    public let capabilityProbes: [ToolchainArchitectureProbe]
    public let slices: [PatchBuildSliceRecord]
    public let symbolChecks: [BuildCommandExecution]
    public let merge: BuildCommandExecution?

    public init(
        formatVersion: Int = PatchBuildRecord.currentFormatVersion,
        projectName: String,
        architecture: PatchBuildOutputArchitecture,
        minimumIOSVersion: String,
        installName: String,
        sourcePath: String,
        outputPath: String,
        recordPath: String,
        toolchain: AppleToolchain,
        architectureResolution: BuildArchitectureResolution,
        capabilityProbes: [ToolchainArchitectureProbe],
        slices: [PatchBuildSliceRecord],
        symbolChecks: [BuildCommandExecution],
        merge: BuildCommandExecution?
    ) {
        self.formatVersion = formatVersion
        self.projectName = projectName
        self.architecture = architecture
        self.minimumIOSVersion = minimumIOSVersion
        self.installName = installName
        self.sourcePath = sourcePath
        self.outputPath = outputPath
        self.recordPath = recordPath
        self.toolchain = toolchain
        self.architectureResolution = architectureResolution
        self.capabilityProbes = capabilityProbes
        self.slices = slices
        self.symbolChecks = symbolChecks
        self.merge = merge
    }
}

public struct PatchBuildSliceRecord: Codable, Equatable, Sendable {
    public let architecture: BuildSliceArchitecture
    public let cpuSubtype: Int32
    public let cpuSubtypeBase: UInt32
    public let cpuSubtypeCapabilities: UInt32
    public let platform: MachOPlatform
    public let minimumOSVersion: String
    public let installName: String
    public let outputPath: String
    public let compilation: BuildCommandExecution

    public init(
        architecture: BuildSliceArchitecture,
        cpuSubtype: Int32,
        cpuSubtypeBase: UInt32,
        cpuSubtypeCapabilities: UInt32,
        platform: MachOPlatform,
        minimumOSVersion: String,
        installName: String,
        outputPath: String,
        compilation: BuildCommandExecution
    ) {
        self.architecture = architecture
        self.cpuSubtype = cpuSubtype
        self.cpuSubtypeBase = cpuSubtypeBase
        self.cpuSubtypeCapabilities = cpuSubtypeCapabilities
        self.platform = platform
        self.minimumOSVersion = minimumOSVersion
        self.installName = installName
        self.outputPath = outputPath
        self.compilation = compilation
    }
}
