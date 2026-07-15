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
    public let sdkPath: String
    public let sdkVersion: String

    public init(
        developerDirectory: String,
        xcodeVersion: String,
        clangPath: String,
        clangVersion: String,
        sdkPath: String,
        sdkVersion: String
    ) {
        self.developerDirectory = developerDirectory
        self.xcodeVersion = xcodeVersion
        self.clangPath = clangPath
        self.clangVersion = clangVersion
        self.sdkPath = sdkPath
        self.sdkVersion = sdkVersion
    }
}

public struct PatchBuildRecord: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let projectName: String
    public let architecture: MachOArchitecture
    public let minimumIOSVersion: String
    public let installName: String
    public let sourcePath: String
    public let outputPath: String
    public let recordPath: String
    public let toolchain: AppleToolchain
    public let compilation: BuildCommandExecution

    public init(
        formatVersion: Int = PatchBuildRecord.currentFormatVersion,
        projectName: String,
        architecture: MachOArchitecture,
        minimumIOSVersion: String,
        installName: String,
        sourcePath: String,
        outputPath: String,
        recordPath: String,
        toolchain: AppleToolchain,
        compilation: BuildCommandExecution
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
        self.compilation = compilation
    }
}
