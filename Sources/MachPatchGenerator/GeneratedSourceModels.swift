import Foundation

public struct GeneratedSourceBundle: Equatable, Sendable {
    public let files: [GeneratedSourceFile]

    public init(files: [GeneratedSourceFile]) {
        self.files = files
    }
}

public struct GeneratedSourceFile: Equatable, Sendable {
    public let relativePath: String
    public let contents: String

    public init(relativePath: String, contents: String) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

public enum GeneratedSourceWriter {
    public static func write(
        _ bundle: GeneratedSourceBundle,
        to outputDirectory: URL
    ) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if isSymbolicLink(at: outputDirectory, fileManager: fileManager) {
            throw GeneratedSourceWriterError.outputDirectoryIsSymbolicLink(
                outputDirectory.path
            )
        }
        if fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw GeneratedSourceWriterError.outputIsNotDirectory(outputDirectory.path)
            }
        } else {
            try fileManager.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }

        var writtenURLs: [URL] = []
        for file in bundle.files {
            guard isSafeRelativeFileName(file.relativePath) else {
                throw GeneratedSourceWriterError.unsafeRelativePath(file.relativePath)
            }
            let destination = outputDirectory.appending(path: file.relativePath)
            if isSymbolicLink(at: destination, fileManager: fileManager) {
                throw GeneratedSourceWriterError.destinationIsSymbolicLink(destination.path)
            }
            try Data(file.contents.utf8).write(to: destination, options: [.atomic])
            writtenURLs.append(destination)
        }
        return writtenURLs
    }

    private static func isSafeRelativeFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }

    private static func isSymbolicLink(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

public enum GeneratedSourceWriterError: Error, Equatable, LocalizedError, Sendable {
    case outputIsNotDirectory(String)
    case outputDirectoryIsSymbolicLink(String)
    case destinationIsSymbolicLink(String)
    case unsafeRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case .outputIsNotDirectory(let path):
            "Generated-source output exists but is not a directory: \(path)"
        case .outputDirectoryIsSymbolicLink(let path):
            "Generated-source output directory must not be a symbolic link: \(path)"
        case .destinationIsSymbolicLink(let path):
            "Generated-source destination must not be a symbolic link: \(path)"
        case .unsafeRelativePath(let path):
            "Generated source has an unsafe relative path: \(path)"
        }
    }
}
