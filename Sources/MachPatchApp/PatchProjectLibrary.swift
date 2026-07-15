import Foundation
import MachPatchCore

struct SavedPatchProject: Identifiable, Equatable, Sendable {
    let fileURL: URL
    let projectName: String
    let targetExecutableName: String
    let patchCount: Int
    let savedAt: Date

    var id: URL { fileURL }
}

protocol PatchProjectLibraryServicing {
    var directoryURL: URL { get }

    func savedProjects() throws -> [SavedPatchProject]
    @discardableResult
    func save(_ project: PatchProject) throws -> SavedPatchProject
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
                targetExecutableName: project.target.executableName,
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
            targetExecutableName: project.target.executableName,
            patchCount: project.patches.count,
            savedAt: savedAt
        )
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
