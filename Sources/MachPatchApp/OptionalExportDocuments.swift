import Foundation
import MachPatchPackager
import SwiftUI
import UniformTypeIdentifiers

struct SourceBundleExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.zip]
    static let writableContentTypes: [UTType] = [.zip]

    private let contents: Data

    init(archive: PatchSourceArchive) {
        contents = archive.contents
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

struct DebianPackageExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.machPatchDebianPackage]
    static let writableContentTypes: [UTType] = [.machPatchDebianPackage]

    private let contents: Data

    init(package: DebianPackage) {
        contents = package.contents
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
    static let machPatchDebianPackage =
        UTType(filenameExtension: "deb", conformingTo: .data) ?? .data
}
