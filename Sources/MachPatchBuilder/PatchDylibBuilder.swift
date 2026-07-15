import Foundation
import MachPatchCore
import MachPatchGenerator

public struct PatchDylibBuilder: Sendable {
    private let commandRunner: any BuildCommandRunning

    public init(commandRunner: any BuildCommandRunning = ProcessBuildCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func build(
        _ project: PatchProject,
        outputDirectory: URL
    ) throws -> PatchBuildRecord {
        try requireOrdinaryArm64(project)

        let sourceBundle = try ObjectiveCSourceGenerator().generate(project)
        let outputDirectory = outputDirectory.standardizedFileURL
        let sourceURL =
            try GeneratedSourceWriter.write(
                sourceBundle,
                to: outputDirectory
            ).first ?? outputDirectory.appending(path: MachPatchGenerator.generatedSourceFileName)

        let outputFileName = "\(project.build.outputName).dylib"
        let outputURL = outputDirectory.appending(path: outputFileName)
        let recordURL = outputDirectory.appending(path: MachPatchBuilder.buildRecordFileName)
        try removePreviousRegularFile(at: outputURL)
        try removePreviousRegularFile(at: recordURL)
        let toolchain = try AppleToolchainDiscoverer(commandRunner: commandRunner).discover()

        let installName = "@rpath/\(outputFileName)"
        let arguments = [
            "-arch", "arm64",
            "-isysroot", toolchain.sdkPath,
            "-miphoneos-version-min=\(project.build.minimumIOSVersion)",
            project.build.enableARC ? "-fobjc-arc" : "-fno-objc-arc",
            "-fblocks",
            "-dynamiclib",
            "-Wall",
            "-Wextra",
            "-framework", "Foundation",
            "-framework", "UIKit",
            "-Wl,-install_name,\(installName)",
            sourceURL.path,
            "-o", outputURL.path,
        ]
        let invocation = BuildCommandInvocation(
            executablePath: toolchain.clangPath,
            arguments: arguments
        )

        let compilation: BuildCommandExecution
        do {
            compilation = try commandRunner.run(invocation)
        } catch {
            try? removeRegularFileIfPresent(at: outputURL)
            throw error
        }
        guard compilation.terminationStatus == 0 else {
            try? removeRegularFileIfPresent(at: outputURL)
            throw PatchDylibBuilderError.compilerFailed(compilation)
        }
        guard isRegularFile(at: outputURL) else {
            try? removeRegularFileIfPresent(at: outputURL)
            throw PatchDylibBuilderError.compilerDidNotProduceOutput(outputURL.path)
        }

        let record = PatchBuildRecord(
            projectName: project.projectName,
            architecture: .arm64,
            minimumIOSVersion: project.build.minimumIOSVersion,
            installName: installName,
            sourcePath: sourceURL.path,
            outputPath: outputURL.path,
            recordPath: recordURL.path,
            toolchain: toolchain,
            compilation: compilation
        )
        do {
            try writeRecord(record, to: recordURL)
        } catch {
            try? removeRegularFileIfPresent(at: outputURL)
            throw error
        }
        return record
    }

    private func requireOrdinaryArm64(_ project: PatchProject) throws {
        guard project.build.architectureMode != .arm64e,
            project.target.selectedSlice.architecture == .arm64
        else {
            throw PatchDylibBuilderError.ordinaryArm64Required(
                mode: project.build.architectureMode,
                target: project.target.selectedSlice.architecture
            )
        }
    }

    private func removePreviousRegularFile(at url: URL) throws {
        let fileManager = FileManager.default
        if isSymbolicLink(at: url) {
            throw PatchDylibBuilderError.unsafeOutputPath(url.path)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }
        guard !isDirectory.boolValue else {
            throw PatchDylibBuilderError.outputCollision(url.path)
        }
        try fileManager.removeItem(at: url)
    }

    private func removeRegularFileIfPresent(at url: URL) throws {
        if isSymbolicLink(at: url) {
            try FileManager.default.removeItem(at: url)
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func isRegularFile(at url: URL) -> Bool {
        guard !isSymbolicLink(at: url) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func writeRecord(_ record: PatchBuildRecord, to url: URL) throws {
        guard !isSymbolicLink(at: url) else {
            throw PatchDylibBuilderError.unsafeOutputPath(url.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)
        try data.write(to: url, options: [.atomic])
    }
}

public enum PatchDylibBuilderError: Error, Equatable, LocalizedError, Sendable {
    case ordinaryArm64Required(mode: PatchArchitectureMode, target: MachOArchitecture)
    case unsafeOutputPath(String)
    case outputCollision(String)
    case compilerFailed(BuildCommandExecution)
    case compilerDidNotProduceOutput(String)

    public var errorDescription: String? {
        switch self {
        case .ordinaryArm64Required(let mode, let target):
            "Milestone 6 builds ordinary arm64 targets only; requested mode '\(mode.rawValue)' for target '\(target.rawValue)'. arm64e capability resolution is implemented in Milestone 7."
        case .unsafeOutputPath(let path):
            "Build output must not replace a symbolic link: \(path)"
        case .outputCollision(let path):
            "Build output collides with a directory: \(path)"
        case .compilerFailed(let execution):
            compilerFailureDescription(execution)
        case .compilerDidNotProduceOutput(let path):
            "Clang reported success but did not produce a regular dylib at: \(path)"
        }
    }

    private func compilerFailureDescription(_ execution: BuildCommandExecution) -> String {
        let value =
            execution.standardError.isEmpty
            ? execution.standardOutput : execution.standardError
        let diagnostics = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = diagnostics.isEmpty ? "" : "\n\(diagnostics)"
        return
            "Clang failed with exit status \(execution.terminationStatus): \(execution.invocation.displayString)\(suffix)"
    }
}
