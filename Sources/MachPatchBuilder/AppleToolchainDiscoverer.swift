import Foundation

public struct AppleToolchainDiscoverer: Sendable {
    private let commandRunner: any BuildCommandRunning

    public init(commandRunner: any BuildCommandRunning = ProcessBuildCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func discover() throws -> AppleToolchain {
        let developerDirectory = try requiredOutput(
            executablePath: "/usr/bin/xcode-select",
            arguments: ["-p"]
        )
        let clangPath = try requiredOutput(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphoneos", "--find", "clang"]
        )
        let sdkPath = try requiredOutput(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphoneos", "--show-sdk-path"]
        )
        let sdkVersion = try requiredOutput(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphoneos", "--show-sdk-version"]
        )
        let xcodeVersion = try requiredOutput(
            executablePath: "/usr/bin/xcrun",
            arguments: ["xcodebuild", "-version"]
        )
        let clangVersion = try requiredOutput(
            executablePath: clangPath,
            arguments: ["--version"]
        )
        let lipoPath = try requiredOutput(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--find", "lipo"]
        )
        let nmPath = try requiredOutput(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--find", "nm"]
        )

        guard developerDirectory.hasPrefix("/"), clangPath.hasPrefix("/"), lipoPath.hasPrefix("/"),
            nmPath.hasPrefix("/"), sdkPath.hasPrefix("/")
        else {
            throw AppleToolchainDiscoveryError.nonAbsolutePath
        }
        return AppleToolchain(
            developerDirectory: developerDirectory,
            xcodeVersion: xcodeVersion,
            clangPath: clangPath,
            clangVersion: clangVersion,
            lipoPath: lipoPath,
            nmPath: nmPath,
            sdkPath: sdkPath,
            sdkVersion: sdkVersion
        )
    }

    private func requiredOutput(
        executablePath: String,
        arguments: [String]
    ) throws -> String {
        let invocation = BuildCommandInvocation(
            executablePath: executablePath,
            arguments: arguments
        )
        let execution = try commandRunner.run(invocation)
        guard execution.terminationStatus == 0 else {
            throw AppleToolchainDiscoveryError.commandFailed(execution)
        }
        let value = execution.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AppleToolchainDiscoveryError.emptyOutput(invocation)
        }
        return value
    }
}

public enum AppleToolchainDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case commandFailed(BuildCommandExecution)
    case emptyOutput(BuildCommandInvocation)
    case nonAbsolutePath

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let execution):
            let diagnostics = diagnosticText(execution)
            return
                "Toolchain discovery failed with exit status \(execution.terminationStatus): \(execution.invocation.displayString)\(diagnostics)"
        case .emptyOutput(let invocation):
            return "Toolchain discovery returned no output: \(invocation.displayString)"
        case .nonAbsolutePath:
            return "Toolchain discovery returned a non-absolute developer, compiler, or SDK path."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .commandFailed, .emptyOutput:
            "Install and open the full Xcode application, then select its developer directory with `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`. MachPatch requires the iPhoneOS SDK; Command Line Tools alone are insufficient."
        case .nonAbsolutePath:
            "Select a valid full-Xcode developer directory with `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`, then try the build again."
        }
    }

    private func diagnosticText(_ execution: BuildCommandExecution) -> String {
        let value =
            execution.standardError.isEmpty
            ? execution.standardOutput : execution.standardError
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "\n\(trimmed)"
    }
}
