import Foundation

public protocol BuildCommandRunning: Sendable {
    func run(_ invocation: BuildCommandInvocation) throws -> BuildCommandExecution
}

public struct ProcessBuildCommandRunner: BuildCommandRunning {
    private static let maximumCapturedBytes: UInt64 = 16 * 1_024 * 1_024

    public init() {}

    public func run(_ invocation: BuildCommandInvocation) throws -> BuildCommandExecution {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appending(
            path: "MachPatchBuildCommand-\(UUID().uuidString)",
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
            throw BuildCommandRunnerError.captureFilesCouldNotBeCreated
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
            throw BuildCommandRunnerError.launchFailed(
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
            throw BuildCommandRunnerError.capturedOutputExceededLimit
        }

        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        let durationMilliseconds = UInt64((elapsed * 1_000).rounded())
        return BuildCommandExecution(
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
            durationMilliseconds: durationMilliseconds
        )
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else {
            throw BuildCommandRunnerError.capturedOutputSizeUnavailable
        }
        return UInt64(size)
    }
}

public enum BuildCommandRunnerError: Error, Equatable, LocalizedError, Sendable {
    case captureFilesCouldNotBeCreated
    case launchFailed(BuildCommandInvocation, String)
    case capturedOutputExceededLimit
    case capturedOutputSizeUnavailable

    public var errorDescription: String? {
        switch self {
        case .captureFilesCouldNotBeCreated:
            "Compiler diagnostic capture files could not be created."
        case .launchFailed(let invocation, let reason):
            "Command could not be launched: \(invocation.displayString) (\(reason))"
        case .capturedOutputExceededLimit:
            "Command diagnostics exceeded the 16 MiB capture limit."
        case .capturedOutputSizeUnavailable:
            "Command diagnostic size is unavailable."
        }
    }
}
