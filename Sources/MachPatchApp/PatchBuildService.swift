import Foundation
import MachPatchBuilder
import MachPatchCore

protocol PatchBuildServicing: Sendable {
    func build(
        project: PatchProject,
        progress: @escaping @Sendable (PatchBuildProgress) -> Void
    ) throws -> PatchBuildArtifact
}

struct PatchBuildService: PatchBuildServicing, Sendable {
    private let builder: PatchDylibBuilder
    private let temporaryDirectory: URL

    init(
        builder: PatchDylibBuilder = PatchDylibBuilder(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.builder = builder
        self.temporaryDirectory = temporaryDirectory
    }

    func build(
        project: PatchProject,
        progress: @escaping @Sendable (PatchBuildProgress) -> Void
    ) throws -> PatchBuildArtifact {
        let workspaceURL = temporaryDirectory.appending(
            path: "MachPatchAppBuild-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let record = try builder.build(
                project,
                outputDirectory: workspaceURL,
                progress: progress
            )
            return PatchBuildArtifact(workspaceURL: workspaceURL, record: record)
        } catch {
            try? FileManager.default.removeItem(at: workspaceURL)
            throw error
        }
    }
}

struct PatchBuildArtifact: Equatable, Sendable {
    let workspaceURL: URL
    let record: PatchBuildRecord

    var dylibURL: URL { URL(filePath: record.outputPath) }
    var sourceURL: URL { URL(filePath: record.sourcePath) }
    var recordURL: URL { URL(filePath: record.recordPath) }
}

struct PatchBuildFailure: Equatable, Sendable {
    let message: String
    let recoverySuggestion: String?
    let command: String?
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32?

    init(error: any Error) {
        message = error.localizedDescription
        recoverySuggestion = (error as? any LocalizedError)?.recoverySuggestion
        let execution = Self.commandExecution(from: error)
        command = execution?.invocation.displayString ?? Self.launchCommand(from: error)
        standardOutput = execution?.standardOutput ?? ""
        standardError = execution?.standardError ?? ""
        terminationStatus = execution?.terminationStatus
    }

    var diagnosticText: String {
        let standardError = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !standardError.isEmpty { return standardError }
        let standardOutput = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !standardOutput.isEmpty { return standardOutput }
        return message
    }

    private static func commandExecution(from error: any Error) -> BuildCommandExecution? {
        if let builderError = error as? PatchDylibBuilderError {
            switch builderError {
            case .compilerFailed(let execution), .symbolInspectionFailed(let execution),
                .mergeFailed(let execution):
                return execution
            case .toolchainArchitectureUnsupported(let probe):
                return probe.execution
            case .unsafeOutputPath, .outputCollision, .compilerDidNotProduceOutput,
                .outputValidationFailed:
                return nil
            }
        }
        if let discoveryError = error as? AppleToolchainDiscoveryError,
            case .commandFailed(let execution) = discoveryError
        {
            return execution
        }
        return nil
    }

    private static func launchCommand(from error: any Error) -> String? {
        guard let runnerError = error as? BuildCommandRunnerError,
            case .launchFailed(let invocation, _) = runnerError
        else { return nil }
        return invocation.displayString
    }
}

enum PatchBuildState: Equatable, Sendable {
    case idle
    case building(PatchBuildProgress, previousArtifact: PatchBuildArtifact?)
    case succeeded(PatchBuildArtifact)
    case failed(PatchBuildFailure, previousArtifact: PatchBuildArtifact?)
    case stale(PatchBuildArtifact)

    var isBuilding: Bool {
        if case .building = self { return true }
        return false
    }

    var artifact: PatchBuildArtifact? {
        switch self {
        case .building(_, let artifact), .failed(_, let artifact):
            artifact
        case .succeeded(let artifact), .stale(let artifact):
            artifact
        case .idle:
            nil
        }
    }
}
