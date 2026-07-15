import Foundation

struct ExternalCommandResult {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

enum ExternalCommandRunner {
    private static let maximumCapturedBytes: UInt64 = 512 * 1_024 * 1_024

    static func run(
        executableURL: URL,
        arguments: [String]
    ) throws -> ExternalCommandResult {
        let fileManager = FileManager.default
        let workspaceURL = fileManager.temporaryDirectory.appending(
            path: "MachPatchCommand-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: workspaceURL) }

        let outputURL = workspaceURL.appending(path: "stdout")
        let errorURL = workspaceURL.appending(path: "stderr")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
            fileManager.createFile(atPath: errorURL.path, contents: nil)
        else {
            throw ExternalCommandError("capture files could not be created")
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()
        try errorHandle.close()

        let outputSize = try fileSize(at: outputURL)
        let errorSize = try fileSize(at: errorURL)
        guard outputSize <= maximumCapturedBytes, errorSize <= maximumCapturedBytes else {
            throw ExternalCommandError("command output exceeded the capture limit")
        }

        return ExternalCommandResult(
            standardOutput: try Data(contentsOf: outputURL, options: [.mappedIfSafe]),
            standardError: try Data(contentsOf: errorURL, options: [.mappedIfSafe]),
            terminationStatus: process.terminationStatus
        )
    }

    private static func fileSize(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else {
            throw ExternalCommandError("captured output size is unavailable")
        }
        return UInt64(size)
    }
}

struct ExternalCommandError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
