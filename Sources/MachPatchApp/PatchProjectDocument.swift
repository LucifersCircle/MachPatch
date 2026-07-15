import Foundation
import MachPatchCore
import SwiftUI
import UniformTypeIdentifiers

struct PatchProjectDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    static let writableContentTypes: [UTType] = [.json]

    let project: PatchProject

    init(project: PatchProject) {
        self.project = project
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try PatchProjectCodec.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try PatchProjectCodec.encode(project))
    }
}
