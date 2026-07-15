import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DylibExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.machPatchDynamicLibrary]
    static let writableContentTypes: [UTType] = [.machPatchDynamicLibrary]

    private let contents: Data

    init(contentsOf url: URL) throws {
        contents = try Data(contentsOf: url, options: .mappedIfSafe)
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.contents = contents
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: contents)
    }
}

extension UTType {
    static let machPatchDynamicLibrary =
        UTType(filenameExtension: "dylib", conformingTo: .data) ?? .data
}
