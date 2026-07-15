import Foundation

public protocol VerificationCommandRunning: Sendable {
    func run(_ invocation: VerificationCommandInvocation) throws -> VerificationCommandExecution
}

public struct ProcessVerificationCommandRunner: VerificationCommandRunning {
    private static let maximumCapturedBytes: UInt64 = 16 * 1_024 * 1_024

    public init() {}

    public func run(
        _ invocation: VerificationCommandInvocation
    ) throws -> VerificationCommandExecution {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appending(
            path: "MachPatchVerifyCommand-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: workspace) }

        let standardOutputURL = workspace.appending(path: "stdout")
        let standardErrorURL = workspace.appending(path: "stderr")
        guard fileManager.createFile(atPath: standardOutputURL.path, contents: nil),
            fileManager.createFile(atPath: standardErrorURL.path, contents: nil)
        else {
            throw VerificationCommandRunnerError.captureFilesCouldNotBeCreated
        }

        let standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
        let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
        defer {
            try? standardOutputHandle.close()
            try? standardErrorHandle.close()
        }

        let process = Process()
        process.executableURL = URL(filePath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            throw VerificationCommandRunnerError.launchFailed(
                invocation,
                error.localizedDescription
            )
        }
        process.waitUntilExit()
        try standardOutputHandle.close()
        try standardErrorHandle.close()

        let outputSize = try fileSize(at: standardOutputURL)
        let errorSize = try fileSize(at: standardErrorURL)
        guard outputSize <= Self.maximumCapturedBytes,
            errorSize <= Self.maximumCapturedBytes
        else {
            throw VerificationCommandRunnerError.capturedOutputExceededLimit
        }

        let duration = max(0, Date().timeIntervalSince(startedAt))
        return VerificationCommandExecution(
            invocation: invocation,
            standardOutput: String(
                decoding: try Data(contentsOf: standardOutputURL, options: [.mappedIfSafe]),
                as: UTF8.self
            ),
            standardError: String(
                decoding: try Data(contentsOf: standardErrorURL, options: [.mappedIfSafe]),
                as: UTF8.self
            ),
            terminationStatus: process.terminationStatus,
            durationMilliseconds: UInt64((duration * 1_000).rounded())
        )
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else {
            throw VerificationCommandRunnerError.capturedOutputSizeUnavailable
        }
        return UInt64(size)
    }
}

public enum VerificationCommandRunnerError: Error, Equatable, LocalizedError, Sendable {
    case captureFilesCouldNotBeCreated
    case launchFailed(VerificationCommandInvocation, String)
    case capturedOutputExceededLimit
    case capturedOutputSizeUnavailable

    public var errorDescription: String? {
        switch self {
        case .captureFilesCouldNotBeCreated:
            "Verification command capture files could not be created."
        case .launchFailed(let invocation, let reason):
            "Verification command could not be launched: \(invocation.executablePath) (\(reason))"
        case .capturedOutputExceededLimit:
            "Verification command output exceeded the 16 MiB capture limit."
        case .capturedOutputSizeUnavailable:
            "Verification command output size is unavailable."
        }
    }
}

public struct VerificationToolDiscoverer: Sendable {
    private let commandRunner: any VerificationCommandRunning

    public init(commandRunner: any VerificationCommandRunning = ProcessVerificationCommandRunner())
    {
        self.commandRunner = commandRunner
    }

    public func discover() throws -> VerificationTools {
        VerificationTools(
            lipoPath: try findTool(named: "lipo"),
            nmPath: try findTool(named: "nm")
        )
    }

    private func findTool(named name: String) throws -> String {
        let invocation = VerificationCommandInvocation(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--find", name]
        )
        let execution = try commandRunner.run(invocation)
        guard execution.terminationStatus == 0 else {
            throw VerificationToolDiscoveryError.commandFailed(execution)
        }
        let path = execution.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw VerificationToolDiscoveryError.invalidPath(name)
        }
        return path
    }
}

public enum VerificationToolDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case commandFailed(VerificationCommandExecution)
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let execution):
            "Verification tool discovery failed with status \(execution.terminationStatus)."
        case .invalidPath(let tool):
            "Verification tool discovery returned an invalid path for \(tool)."
        }
    }
}
