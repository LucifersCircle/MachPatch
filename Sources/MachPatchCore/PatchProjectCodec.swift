import Foundation

public enum PatchProjectCodec {
    public static let maximumProjectBytes = 16 * 1_024 * 1_024

    public static func decode(_ data: Data) throws -> PatchProject {
        guard data.count <= maximumProjectBytes else {
            throw PatchProjectCodecError.projectTooLarge(data.count)
        }
        let project = try JSONDecoder().decode(PatchProject.self, from: data)
        guard project.formatVersion == PatchProject.currentFormatVersion else {
            throw PatchProjectCodecError.unsupportedFormatVersion(project.formatVersion)
        }
        return project
    }

    public static func encode(_ project: PatchProject) throws -> Data {
        guard project.formatVersion == PatchProject.currentFormatVersion else {
            throw PatchProjectCodecError.unsupportedFormatVersion(project.formatVersion)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(project)
        data.append(0x0A)
        return data
    }
}

public enum PatchProjectCodecError: Error, Equatable, LocalizedError, Sendable {
    case projectTooLarge(Int)
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .projectTooLarge(let byteCount):
            "Patch project is \(byteCount) bytes; the maximum is \(PatchProjectCodec.maximumProjectBytes)."
        case .unsupportedFormatVersion(let version):
            "Patch project format version \(version) is unsupported; expected version \(PatchProject.currentFormatVersion)."
        }
    }
}
