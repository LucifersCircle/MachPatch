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

        if values.isDirectory == true, sourceURL.pathExtension.lowercased() == "framework" {
            return try body(try resolveFramework(at: sourceURL))
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
        let mainImage = try resolveBundleImage(
            at: applicationURL,
            kind: .mainExecutable,
            relativeTo: applicationURL
        )
        let discovery = discoverEmbeddedImages(in: applicationURL)

        return ResolvedTarget(
            sourceType: type,
            sourcePath: sourceURL.path,
            bundlePath: applicationURL.path,
            bundleIdentifier: mainImage.bundleIdentifier,
            displayName: mainImage.displayName,
            minimumOSVersion: mainImage.minimumOSVersion,
            supportedPlatforms: mainImage.supportedPlatforms,
            executableName: mainImage.executableName,
            executablePath: mainImage.executablePath,
            sha256: mainImage.sha256,
            images: [mainImage] + discovery.images,
            imageDiscoveryIssues: discovery.issues
        )
    }

    private func resolveFramework(at frameworkURL: URL) throws -> ResolvedTarget {
        let image = try resolveBundleImage(
            at: frameworkURL,
            kind: .standaloneFramework,
            relativeTo: frameworkURL
        )
        return ResolvedTarget(
            sourceType: .frameworkBundle,
            sourcePath: frameworkURL.path,
            bundlePath: frameworkURL.path,
            bundleIdentifier: image.bundleIdentifier,
            displayName: image.displayName,
            minimumOSVersion: image.minimumOSVersion,
            supportedPlatforms: image.supportedPlatforms,
            executableName: image.executableName,
            executablePath: image.executablePath,
            sha256: image.sha256,
            images: [image]
        )
    }

    private func resolveBundleImage(
        at bundleURL: URL,
        kind: ResolvedImageKind,
        relativeTo rootBundleURL: URL
    ) throws -> ResolvedImage {
        let dictionary = try readBundleInfo(at: bundleURL)
        let infoPlistURL = bundleURL.appending(
            path: "Info.plist", directoryHint: .notDirectory)
        guard let executableName = dictionary["CFBundleExecutable"] as? String,
            !executableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw InputResolutionError.missingBundleExecutable(infoPlistURL.path)
        }
        guard isSafeExecutableName(executableName) else {
            throw InputResolutionError.unsafeExecutableName(executableName)
        }

        let executableURL = bundleURL.appending(
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

        let relativePath = relativePath(of: executableURL, from: rootBundleURL)
        return ResolvedImage(
            id: "\(kind.rawValue):\(relativePath)",
            kind: kind,
            relativePath: relativePath,
            bundlePath: bundleURL.path,
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

    private func readBundleInfo(at bundleURL: URL) throws -> [String: Any] {
        let infoPlistURL = bundleURL.appending(
            path: "Info.plist", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            throw InputResolutionError.missingInfoPlist(infoPlistURL.path)
        }

        do {
            let data = try Data(contentsOf: infoPlistURL, options: [.mappedIfSafe])
            let propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            guard let dictionary = propertyList as? [String: Any] else {
                throw InputResolutionError.unreadableInfoPlist("root value is not a dictionary")
            }
            return dictionary
        } catch let error as InputResolutionError {
            throw error
        } catch {
            throw InputResolutionError.unreadableInfoPlist(error.localizedDescription)
        }
    }

    private func discoverEmbeddedImages(
        in applicationURL: URL
    ) -> (images: [ResolvedImage], issues: [ResolvedImageDiscoveryIssue]) {
        var images: [ResolvedImage] = []
        var issues: [ResolvedImageDiscoveryIssue] = []

        let applicationFrameworks = discoverBundles(
            in: applicationURL.appending(path: "Frameworks", directoryHint: .isDirectory),
            pathExtension: "framework",
            kind: .dynamicFramework,
            relativeTo: applicationURL
        )
        images.append(contentsOf: applicationFrameworks.images)
        issues.append(contentsOf: applicationFrameworks.issues)

        let extensions = discoverBundles(
            in: applicationURL.appending(path: "PlugIns", directoryHint: .isDirectory),
            pathExtension: "appex",
            kind: .appExtension,
            relativeTo: applicationURL
        )
        images.append(contentsOf: extensions.images)
        issues.append(contentsOf: extensions.issues)

        for appExtension in extensions.images {
            guard let bundlePath = appExtension.bundlePath else { continue }
            let extensionFrameworks = discoverBundles(
                in: URL(filePath: bundlePath, directoryHint: .isDirectory)
                    .appending(path: "Frameworks", directoryHint: .isDirectory),
                pathExtension: "framework",
                kind: .dynamicFramework,
                relativeTo: applicationURL
            )
            images.append(contentsOf: extensionFrameworks.images)
            issues.append(contentsOf: extensionFrameworks.issues)
        }

        return (
            images.sorted { $0.relativePath < $1.relativePath },
            issues.sorted { $0.relativeBundlePath < $1.relativeBundlePath }
        )
    }

    private func discoverBundles(
        in directoryURL: URL,
        pathExtension: String,
        kind: ResolvedImageKind,
        relativeTo rootBundleURL: URL
    ) -> (images: [ResolvedImage], issues: [ResolvedImageDiscoveryIssue]) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return ([], []) }

        let directoryValues = try? directoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard directoryValues?.isDirectory == true, directoryValues?.isSymbolicLink != true else {
            let path = relativePath(of: directoryURL, from: rootBundleURL)
            return (
                [],
                [
                    ResolvedImageDiscoveryIssue(
                        kind: kind,
                        relativeBundlePath: path,
                        message: "Embedded image directory is not a safe directory."
                    )
                ]
            )
        }

        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == pathExtension }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            let path = relativePath(of: directoryURL, from: rootBundleURL)
            return (
                [],
                [
                    ResolvedImageDiscoveryIssue(
                        kind: kind,
                        relativeBundlePath: path,
                        message:
                            "Embedded image directory could not be read: \(error.localizedDescription)"
                    )
                ]
            )
        }

        var images: [ResolvedImage] = []
        var issues: [ResolvedImageDiscoveryIssue] = []
        for candidate in candidates {
            let candidatePath = relativePath(of: candidate, from: rootBundleURL)
            let values = try? candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                issues.append(
                    ResolvedImageDiscoveryIssue(
                        kind: kind,
                        relativeBundlePath: candidatePath,
                        message: "Embedded image bundle is not a safe directory."
                    ))
                continue
            }

            do {
                images.append(
                    try resolveBundleImage(
                        at: candidate,
                        kind: kind,
                        relativeTo: rootBundleURL
                    ))
            } catch {
                issues.append(
                    ResolvedImageDiscoveryIssue(
                        kind: kind,
                        relativeBundlePath: candidatePath,
                        message: error.localizedDescription
                    ))
            }
        }
        return (images, issues)
    }

    private func relativePath(of itemURL: URL, from rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let itemPath = itemURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else { return itemURL.lastPathComponent }
        return String(itemPath.dropFirst(prefix.count))
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
