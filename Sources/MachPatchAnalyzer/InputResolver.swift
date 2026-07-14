import CryptoKit
import Foundation
import MachPatchCore

/// Resolves supported inputs while keeping temporary IPA extraction scoped to an operation.
public struct InputResolver: Sendable {
    private let temporaryDirectoryURL: URL

    public init(temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectoryURL = temporaryDirectoryURL.standardizedFileURL
    }

    /// Resolves an input and keeps any extracted IPA files alive only for the duration of `body`.
    /// Temporary files are removed whether `body` succeeds or throws.
    public func withResolvedTarget<Result>(
        at inputURL: URL,
        _ body: (ResolvedTarget) throws -> Result
    ) throws -> Result {
        let sourceURL = inputURL.standardizedFileURL
        let values: URLResourceValues

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw InputResolutionError.pathDoesNotExist(sourceURL.path)
        }

        do {
            values = try sourceURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw InputResolutionError.unsupportedInput(sourceURL.path)
        }

        if values.isSymbolicLink == true {
            throw InputResolutionError.inputIsSymbolicLink(sourceURL.path)
        }

        if values.isDirectory == true, sourceURL.pathExtension.lowercased() == "app" {
            return try body(
                try resolveApplication(at: sourceURL, source: sourceURL, type: .applicationBundle))
        }

        if values.isRegularFile == true, sourceURL.pathExtension.lowercased() == "ipa" {
            return try withExtractedIPA(at: sourceURL, body)
        }

        if values.isRegularFile == true, isMachO(at: sourceURL) {
            return try body(try resolveMachO(at: sourceURL))
        }

        throw InputResolutionError.unsupportedInput(sourceURL.path)
    }

    private func withExtractedIPA<Result>(
        at sourceURL: URL,
        _ body: (ResolvedTarget) throws -> Result
    ) throws -> Result {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: temporaryDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw InputResolutionError.archiveExtractionFailed(
                "temporary directory could not be created: \(error.localizedDescription)"
            )
        }

        let workspaceURL = temporaryDirectoryURL.appending(
            path: "MachPatch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try fileManager.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw InputResolutionError.archiveExtractionFailed(
                "workspace could not be created: \(error.localizedDescription)"
            )
        }
        defer { try? fileManager.removeItem(at: workspaceURL) }

        let archiveSnapshotURL = workspaceURL.appending(path: "Input.ipa")
        let extractionURL = workspaceURL.appending(path: "Extracted", directoryHint: .isDirectory)
        do {
            try fileManager.copyItem(at: sourceURL, to: archiveSnapshotURL)
            let snapshotValues = try archiveSnapshotURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard snapshotValues.isRegularFile == true, snapshotValues.isSymbolicLink != true else {
                throw InputResolutionError.unsafeArchive("input snapshot is not a regular file")
            }
        } catch let error as InputResolutionError {
            throw error
        } catch {
            throw InputResolutionError.archiveExtractionFailed(
                "input snapshot could not be created: \(error.localizedDescription)"
            )
        }

        do {
            try ZipArchiveValidator.validateArchive(at: archiveSnapshotURL)
        } catch {
            throw InputResolutionError.unsafeArchive(error.localizedDescription)
        }

        do {
            try fileManager.createDirectory(
                at: extractionURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw InputResolutionError.archiveExtractionFailed(
                "extraction directory could not be created: \(error.localizedDescription)"
            )
        }

        try extractArchive(archiveSnapshotURL, to: extractionURL)
        try rejectExtractedSymbolicLinks(in: extractionURL)

        let payloadURL = extractionURL.appending(path: "Payload", directoryHint: .isDirectory)
        let payloadValues = try? payloadURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard payloadValues?.isDirectory == true, payloadValues?.isSymbolicLink != true else {
            throw InputResolutionError.missingPayload
        }

        let applications: [URL]
        do {
            applications = try fileManager.contentsOfDirectory(
                at: payloadURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).filter { candidate in
                guard candidate.pathExtension.lowercased() == "app" else { return false }
                let candidateValues = try? candidate.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                return candidateValues?.isDirectory == true
                    && candidateValues?.isSymbolicLink != true
            }.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        } catch {
            throw InputResolutionError.invalidApplicationBundle(payloadURL.path)
        }

        guard !applications.isEmpty else {
            throw InputResolutionError.missingApplication
        }
        guard applications.count == 1, let applicationURL = applications.first else {
            throw InputResolutionError.multipleApplications(
                applications.map(\.lastPathComponent)
            )
        }

        let target = try resolveApplication(
            at: applicationURL,
            source: sourceURL,
            type: .ipa
        )
        return try body(target)
    }

    private func resolveApplication(
        at applicationURL: URL,
        source sourceURL: URL,
        type: InputKind
    ) throws -> ResolvedTarget {
        let infoPlistURL = applicationURL.appending(
            path: "Info.plist", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            throw InputResolutionError.missingInfoPlist(infoPlistURL.path)
        }

        let dictionary: [String: Any]
        do {
            let data = try Data(contentsOf: infoPlistURL, options: [.mappedIfSafe])
            let propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            guard let decodedDictionary = propertyList as? [String: Any] else {
                throw InputResolutionError.unreadableInfoPlist("root value is not a dictionary")
            }
            dictionary = decodedDictionary
        } catch let error as InputResolutionError {
            throw error
        } catch {
            throw InputResolutionError.unreadableInfoPlist(error.localizedDescription)
        }

        guard let executableName = dictionary["CFBundleExecutable"] as? String,
            !executableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw InputResolutionError.missingBundleExecutable(infoPlistURL.path)
        }
        guard isSafeExecutableName(executableName) else {
            throw InputResolutionError.unsafeExecutableName(executableName)
        }

        let executableURL = applicationURL.appending(
            path: executableName,
            directoryHint: .notDirectory
        )
        let executableValues = try? executableURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        if executableValues?.isSymbolicLink == true {
            throw InputResolutionError.executableIsSymbolicLink(executableURL.path)
        }
        guard executableValues?.isRegularFile == true else {
            throw InputResolutionError.executableNotFound(executableURL.path)
        }
        guard isMachO(at: executableURL) else {
            throw InputResolutionError.executableIsNotMachO(executableURL.path)
        }

        return ResolvedTarget(
            sourceType: type,
            sourcePath: sourceURL.path,
            bundlePath: applicationURL.path,
            bundleIdentifier: dictionary["CFBundleIdentifier"] as? String,
            displayName: (dictionary["CFBundleDisplayName"] as? String)
                ?? (dictionary["CFBundleName"] as? String),
            minimumOSVersion: dictionary["MinimumOSVersion"] as? String,
            supportedPlatforms: dictionary["CFBundleSupportedPlatforms"] as? [String] ?? [],
            executableName: executableName,
            executablePath: executableURL.path,
            sha256: try sha256(of: executableURL)
        )
    }

    private func resolveMachO(at executableURL: URL) throws -> ResolvedTarget {
        ResolvedTarget(
            sourceType: .machO,
            sourcePath: executableURL.path,
            bundlePath: nil,
            bundleIdentifier: nil,
            displayName: nil,
            minimumOSVersion: nil,
            supportedPlatforms: [],
            executableName: executableURL.lastPathComponent,
            executablePath: executableURL.path,
            sha256: try sha256(of: executableURL)
        )
    }

    private func extractArchive(_ archiveURL: URL, to workspaceURL: URL) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, workspaceURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw InputResolutionError.archiveExtractionFailed(error.localizedDescription)
        }

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                throw InputResolutionError.archiveExtractionFailed(message)
            }
            throw InputResolutionError.archiveExtractionFailed(
                "ditto exited with status \(process.terminationStatus)"
            )
        }
    }

    private func rejectExtractedSymbolicLinks(in workspaceURL: URL) throws {
        guard
            let enumerator = FileManager.default.enumerator(
                at: workspaceURL,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
        else {
            throw InputResolutionError.archiveExtractionFailed("workspace could not be enumerated")
        }

        for case let itemURL as URL in enumerator {
            let values = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw InputResolutionError.unsafeArchive(
                    "extracted symbolic link is not allowed: \(itemURL.lastPathComponent)"
                )
            }
        }
    }

    private func isSafeExecutableName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("\0")
    }

    private func isMachO(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }

        return switch Array(magic) {
        case [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCE],
            [0xCF, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF],
            [0xCA, 0xFE, 0xBA, 0xBE],
            [0xBE, 0xBA, 0xFE, 0xCA],
            [0xCA, 0xFE, 0xBA, 0xBF],
            [0xBF, 0xBA, 0xFE, 0xCA]:
            true
        default:
            false
        }
    }

    private func sha256(of url: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw InputResolutionError.hashingFailed(error.localizedDescription)
        }
    }
}
