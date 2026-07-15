import Foundation
import MachPatchBuilder
import MachPatchCore

public struct PackagedFile: Equatable, Sendable {
    public let relativePath: String
    public let contents: Data
    public let isExecutable: Bool

    public init(relativePath: String, contents: Data, isExecutable: Bool = false) {
        self.relativePath = relativePath
        self.contents = contents
        self.isExecutable = isExecutable
    }
}

public struct PatchSourceBundle: Equatable, Sendable {
    public let directoryName: String
    public let files: [PackagedFile]

    public init(directoryName: String, files: [PackagedFile]) {
        self.directoryName = directoryName
        self.files = files
    }
}

public struct PatchSourceArchive: Equatable, Sendable {
    public let filename: String
    public let contents: Data

    public init(filename: String, contents: Data) {
        self.filename = filename
        self.contents = contents
    }
}

public struct DebianPackage: Equatable, Sendable {
    public let filename: String
    public let packageIdentifier: String
    public let contents: Data

    public init(filename: String, packageIdentifier: String, contents: Data) {
        self.filename = filename
        self.packageIdentifier = packageIdentifier
        self.contents = contents
    }
}

public enum PatchPackagingError: Error, Equatable, LocalizedError, Sendable {
    case invalidProject([String])
    case buildRecordMismatch(String)
    case unreadableArtifact(String)
    case symbolicLinkArtifact(String)
    case artifactTooLarge(String)
    case bundleIdentifierRequired
    case unsupportedDebianArchitecture(PatchBuildOutputArchitecture)
    case archiveFieldTooLong(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProject(let messages):
            "The patch project is invalid: \(messages.joined(separator: " "))"
        case .buildRecordMismatch(let message):
            "The build record does not match the patch project: \(message)"
        case .unreadableArtifact(let path):
            "The build artifact is missing or unreadable: \(path)"
        case .symbolicLinkArtifact(let path):
            "Packaging does not follow symbolic-link artifacts: \(path)"
        case .artifactTooLarge(let path):
            "The build artifact is too large to package safely: \(path)"
        case .bundleIdentifierRequired:
            "A bundle identifier is required to create a MobileSubstrate filter plist."
        case .unsupportedDebianArchitecture(let architecture):
            "Debian export currently supports ordinary arm64 output only; this build is \(architecture.rawValue)."
        case .archiveFieldTooLong(let value):
            "A package archive field is too long: \(value)"
        }
    }
}

enum ArtifactPackagingValidator {
    static let maximumArtifactSize = 512 * 1_024 * 1_024

    static func validate(
        project: PatchProject,
        buildRecord: PatchBuildRecord,
        artifactURL: URL,
        expectedRecordedPath: String,
        expectedSHA256: String?
    ) throws -> Data {
        let report = PatchProjectValidator.validate(project)
        guard report.isValid else {
            throw PatchPackagingError.invalidProject(report.errors.map(\.message))
        }
        guard buildRecord.projectName == project.projectName else {
            throw PatchPackagingError.buildRecordMismatch("project names differ")
        }
        guard buildRecord.minimumIOSVersion == project.build.minimumIOSVersion else {
            throw PatchPackagingError.buildRecordMismatch("minimum iOS versions differ")
        }
        let expectedInstallName = "@rpath/\(project.build.outputName).dylib"
        guard buildRecord.installName == expectedInstallName else {
            throw PatchPackagingError.buildRecordMismatch("install names differ")
        }
        if let provenance = buildRecord.provenance {
            guard
                provenance.targetExecutableSHA256.caseInsensitiveCompare(
                    project.target.executableSHA256
                ) == .orderedSame
            else {
                throw PatchPackagingError.buildRecordMismatch("target executable hashes differ")
            }
            guard
                provenance.selectedImageSHA256.caseInsensitiveCompare(
                    project.target.selectedImage.executableSHA256
                ) == .orderedSame
            else {
                throw PatchPackagingError.buildRecordMismatch("selected image hashes differ")
            }
            let projectSHA256 = PatchBuildContentHasher.sha256(
                try PatchProjectCodec.encode(project)
            )
            guard provenance.projectSHA256 == projectSHA256 else {
                throw PatchPackagingError.buildRecordMismatch("project hashes differ")
            }
        }
        guard
            artifactURL.standardizedFileURL.path
                == URL(filePath: expectedRecordedPath)
                .standardizedFileURL.path
        else {
            throw PatchPackagingError.buildRecordMismatch("artifact paths differ")
        }

        let values: URLResourceValues
        do {
            values = try artifactURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw PatchPackagingError.unreadableArtifact(artifactURL.path)
        }
        guard values.isSymbolicLink != true else {
            throw PatchPackagingError.symbolicLinkArtifact(artifactURL.path)
        }
        guard values.isRegularFile == true else {
            throw PatchPackagingError.unreadableArtifact(artifactURL.path)
        }
        guard let fileSize = values.fileSize, fileSize <= maximumArtifactSize else {
            throw PatchPackagingError.artifactTooLarge(artifactURL.path)
        }
        do {
            let data = try Data(contentsOf: artifactURL, options: .mappedIfSafe)
            if let expectedSHA256,
                PatchBuildContentHasher.sha256(data) != expectedSHA256
            {
                throw PatchPackagingError.buildRecordMismatch(
                    "artifact content hash differs for \(artifactURL.lastPathComponent)"
                )
            }
            return data
        } catch let error as PatchPackagingError {
            throw error
        } catch {
            throw PatchPackagingError.unreadableArtifact(artifactURL.path)
        }
    }
}
