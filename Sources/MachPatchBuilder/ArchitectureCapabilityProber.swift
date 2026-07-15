import Foundation
import MachPatchAnalyzer
import MachPatchCore

public struct ToolchainArchitectureProbe: Codable, Equatable, Sendable {
    public let requestedArchitecture: BuildSliceArchitecture
    public let supported: Bool
    public let execution: BuildCommandExecution
    public let outputArchitecture: MachOArchitecture?
    public let outputCPUSubtype: Int32?
    public let outputCPUSubtypeBase: UInt32?
    public let outputCPUSubtypeCapabilities: UInt32?
    public let outputPlatform: MachOPlatform?
    public let outputMinimumOSVersion: String?
    public let failureReason: String?

    public init(
        requestedArchitecture: BuildSliceArchitecture,
        supported: Bool,
        execution: BuildCommandExecution,
        outputArchitecture: MachOArchitecture?,
        outputCPUSubtype: Int32?,
        outputCPUSubtypeBase: UInt32?,
        outputCPUSubtypeCapabilities: UInt32?,
        outputPlatform: MachOPlatform?,
        outputMinimumOSVersion: String?,
        failureReason: String?
    ) {
        self.requestedArchitecture = requestedArchitecture
        self.supported = supported
        self.execution = execution
        self.outputArchitecture = outputArchitecture
        self.outputCPUSubtype = outputCPUSubtype
        self.outputCPUSubtypeBase = outputCPUSubtypeBase
        self.outputCPUSubtypeCapabilities = outputCPUSubtypeCapabilities
        self.outputPlatform = outputPlatform
        self.outputMinimumOSVersion = outputMinimumOSVersion
        self.failureReason = failureReason
    }
}

public protocol ToolchainArchitectureProbing: Sendable {
    func probe(
        _ architecture: BuildSliceArchitecture,
        toolchain: AppleToolchain,
        minimumIOSVersion: String
    ) throws -> ToolchainArchitectureProbe
}

public struct ClangArchitectureCapabilityProber: ToolchainArchitectureProbing {
    private let commandRunner: any BuildCommandRunning

    public init(commandRunner: any BuildCommandRunning = ProcessBuildCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func probe(
        _ architecture: BuildSliceArchitecture,
        toolchain: AppleToolchain,
        minimumIOSVersion: String
    ) throws -> ToolchainArchitectureProbe {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appending(
            path: "MachPatchArchitectureProbe-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: workspace) }

        let sourceURL = workspace.appending(path: "ArchitectureProbe.m")
        let outputURL = workspace.appending(path: "ArchitectureProbe.dylib")
        try Data("void MachPatchArchitectureProbe(void) {}\n".utf8).write(
            to: sourceURL,
            options: [.atomic]
        )
        let invocation = BuildCommandInvocation(
            executablePath: toolchain.clangPath,
            arguments: [
                "-arch", architecture.clangName,
                "-isysroot", toolchain.sdkPath,
                "-miphoneos-version-min=\(minimumIOSVersion)",
                "-dynamiclib",
                "-Wl,-install_name,@rpath/MachPatchArchitectureProbe.dylib",
                sourceURL.path,
                "-o", outputURL.path,
            ]
        )
        let execution = try commandRunner.run(invocation)
        guard execution.terminationStatus == 0 else {
            return ToolchainArchitectureProbe(
                requestedArchitecture: architecture,
                supported: false,
                execution: execution,
                outputArchitecture: nil,
                outputCPUSubtype: nil,
                outputCPUSubtypeBase: nil,
                outputCPUSubtypeCapabilities: nil,
                outputPlatform: nil,
                outputMinimumOSVersion: nil,
                failureReason: diagnosticText(execution)
            )
        }

        let slices = try MachOInspector().inspect(at: outputURL)
        guard slices.count == 1, let slice = slices.first else {
            throw ArchitectureCapabilityProbeError.unexpectedSliceCount(slices.count)
        }
        return ToolchainArchitectureProbe(
            requestedArchitecture: architecture,
            supported: true,
            execution: execution,
            outputArchitecture: slice.architecture,
            outputCPUSubtype: slice.cpuSubtype,
            outputCPUSubtypeBase: slice.cpuSubtypeBase,
            outputCPUSubtypeCapabilities: slice.cpuSubtypeCapabilities,
            outputPlatform: slice.platform,
            outputMinimumOSVersion: slice.minimumOSVersion,
            failureReason: nil
        )
    }

    private func diagnosticText(_ execution: BuildCommandExecution) -> String {
        let value =
            execution.standardError.isEmpty
            ? execution.standardOutput : execution.standardError
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "Compiler rejected the architecture probe without diagnostics." : trimmed
    }
}

public enum ArchitectureCapabilityProbeError: Error, Equatable, LocalizedError, Sendable {
    case unexpectedSliceCount(Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedSliceCount(let count):
            "Architecture probe produced \(count) Mach-O slices; expected exactly one."
        }
    }
}
