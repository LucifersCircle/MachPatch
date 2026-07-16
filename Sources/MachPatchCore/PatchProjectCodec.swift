import Foundation

public enum PatchProjectCodec {
    public static let maximumProjectBytes = 16 * 1_024 * 1_024

    public static func decode(_ data: Data) throws -> PatchProject {
        guard data.count <= maximumProjectBytes else {
            throw PatchProjectCodecError.projectTooLarge(data.count)
        }
        let project: PatchProject
        do {
            project = try JSONDecoder().decode(PatchProject.self, from: data)
        } catch let error as DecodingError {
            throw PatchProjectCodecError.invalidJSON(decodingMessage(error))
        }
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

    private static func decodingMessage(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing required field “\(codingPath(context.codingPath, appending: key))”."
        case .typeMismatch(_, let context):
            return
                "Field “\(codingPath(context.codingPath))” has the wrong value type. \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return
                "Field “\(codingPath(context.codingPath))” cannot be null. \(context.debugDescription)"
        case .dataCorrupted(let context):
            return
                "Invalid value at \(codingPath(context.codingPath, quoted: true)). \(context.debugDescription)"
        @unknown default:
            return "The JSON structure could not be decoded."
        }
    }

    private static func codingPath(
        _ path: [any CodingKey],
        appending key: (any CodingKey)? = nil,
        quoted: Bool = false
    ) -> String {
        var keys = path
        if let key { keys.append(key) }
        guard !keys.isEmpty else { return "the project root" }
        var result = ""
        for key in keys {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                if !result.isEmpty { result += "." }
                result += key.stringValue
            }
        }
        return quoted ? "“\(result)”" : result
    }
}

public enum PatchProjectCodecError: Error, Equatable, LocalizedError, Sendable {
    case projectTooLarge(Int)
    case unsupportedFormatVersion(Int)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .projectTooLarge(let byteCount):
            "Patch project is \(byteCount) bytes; the maximum is \(PatchProjectCodec.maximumProjectBytes)."
        case .unsupportedFormatVersion(let version):
            "Patch project format version \(version) is unsupported; expected version \(PatchProject.currentFormatVersion)."
        case .invalidJSON(let message):
            "The selected file is not valid MachPatch project JSON. \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .projectTooLarge:
            "Patch projects contain configuration only. Remove embedded source, binary, or unrelated data and import the JSON again."
        case .unsupportedFormatVersion:
            "Open the project with the MachPatch version that created it, or export it again using the current project format."
        case .invalidJSON:
            "Compare the file with Examples/ExamplePatch.json or run `machpatch validate-project <file>` for the same diagnostic in Terminal."
        }
    }
}
