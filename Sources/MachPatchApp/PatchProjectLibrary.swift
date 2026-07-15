import Foundation
import MachPatchCore

struct SavedPatchProject: Identifiable, Equatable, Sendable {
    let fileURL: URL
    let projectName: String
    let target: PatchTargetIdentity
    let patchCount: Int
    let savedAt: Date

    var id: URL { fileURL }

    var targetExecutableName: String { target.executableName }

    func isRelevant(to currentTarget: PatchTargetIdentity) -> Bool {
        guard target.executableName == currentTarget.executableName,
            target.selectedSlice == currentTarget.selectedSlice
        else { return false }

        if target.executableSHA256.caseInsensitiveCompare(currentTarget.executableSHA256)
            == .orderedSame
        {
            return true
        }
        guard let savedBundleIdentifier = target.bundleIdentifier,
            let currentBundleIdentifier = currentTarget.bundleIdentifier
        else { return false }
        return savedBundleIdentifier == currentBundleIdentifier
    }

    func isExactExecutableMatch(to currentTarget: PatchTargetIdentity) -> Bool {
        target.executableSHA256.caseInsensitiveCompare(currentTarget.executableSHA256)
            == .orderedSame
            && target.executableName == currentTarget.executableName
            && target.selectedSlice == currentTarget.selectedSlice
    }
}

protocol PatchProjectLibraryServicing {
    var directoryURL: URL { get }

    func savedProjects() throws -> [SavedPatchProject]
    @discardableResult
    func save(_ project: PatchProject) throws -> SavedPatchProject
    func delete(_ savedProject: SavedPatchProject) throws
}

struct PatchProjectLibrary: PatchProjectLibraryServicing {
    let directoryURL: URL

    init(directoryURL: URL = Self.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    static var defaultDirectoryURL: URL {
        let applicationSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(
                path: "Library/Application Support",
                directoryHint: .isDirectory
            )
        return
            applicationSupport
            .appending(path: "MachPatch", directoryHint: .isDirectory)
            .appending(path: "Saved Patches", directoryHint: .isDirectory)
    }

    func savedProjects() throws -> [SavedPatchProject] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return try files.compactMap { fileURL in
            guard fileURL.pathExtension.lowercased() == "json" else { return nil }
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let project = try PatchProjectCodec.decode(Data(contentsOf: fileURL))
            return SavedPatchProject(
                fileURL: fileURL,
                projectName: project.projectName,
                target: project.target,
                patchCount: project.patches.count,
                savedAt: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted {
            if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
            return $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending
        }
    }

    @discardableResult
    func save(_ project: PatchProject) throws -> SavedPatchProject {
        try createDirectoryIfNeeded()
        let fileURL = directoryURL.appending(
            path: filename(for: project), directoryHint: .notDirectory)
        try PatchProjectCodec.encode(project).write(to: fileURL, options: [.atomic])
        let savedAt =
            try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate ?? Date()
        return SavedPatchProject(
            fileURL: fileURL,
            projectName: project.projectName,
            target: project.target,
            patchCount: project.patches.count,
            savedAt: savedAt
        )
    }

    func delete(_ savedProject: SavedPatchProject) throws {
        let fileURL = savedProject.fileURL.standardizedFileURL
        let parentURL = fileURL.deletingLastPathComponent().standardizedFileURL
        guard parentURL == directoryURL.standardizedFileURL,
            fileURL.pathExtension.lowercased() == "json"
        else {
            throw PatchProjectLibraryError.invalidSavedProject
        }

        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PatchProjectLibraryError.invalidSavedProject
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func filename(for project: PatchProject) -> String {
        let stem = sanitizedFilenameStem(project.projectName)
        let targetFingerprint = project.target.executableSHA256.prefix(12)
        return "\(stem)-\(targetFingerprint).json"
    }

    private func sanitizedFilenameStem(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var result = ""
        var needsSeparator = false

        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                if needsSeparator, !result.isEmpty, result.last != "-" {
                    result.append("-")
                }
                result.unicodeScalars.append(scalar)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
            if result.count >= 72 { break }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).isEmpty
            ? "Patch"
            : result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }
}

enum PatchProjectLibraryError: LocalizedError, Equatable {
    case invalidSavedProject

    var errorDescription: String? {
        switch self {
        case .invalidSavedProject:
            "The selected file is not a regular saved patch in MachPatch’s private library."
        }
    }
}
