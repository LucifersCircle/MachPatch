import Foundation

struct TarEntry {
    let path: String
    let contents: Data
    let mode: Int
    let isDirectory: Bool
}

enum TarArchiveWriter {
    private static let blockSize = 512

    static func encode(_ entries: [TarEntry]) throws -> Data {
        var archive = Data()
        for entry in entries {
            let contents = entry.isDirectory ? Data() : entry.contents
            var header = [UInt8](repeating: 0, count: blockSize)
            try write(entry.path, to: &header, offset: 0, width: 100)
            try writeOctal(entry.mode, to: &header, offset: 100, width: 8)
            try writeOctal(0, to: &header, offset: 108, width: 8)
            try writeOctal(0, to: &header, offset: 116, width: 8)
            try writeOctal(contents.count, to: &header, offset: 124, width: 12)
            try writeOctal(0, to: &header, offset: 136, width: 12)
            for index in 148..<156 { header[index] = 0x20 }
            header[156] =
                entry.isDirectory ? Character("5").asciiValue! : Character("0").asciiValue!
            try write("ustar", to: &header, offset: 257, width: 6)
            try write("00", to: &header, offset: 263, width: 2)
            try write("root", to: &header, offset: 265, width: 32)
            try write("wheel", to: &header, offset: 297, width: 32)
            try writeOctal(0, to: &header, offset: 329, width: 8)
            try writeOctal(0, to: &header, offset: 337, width: 8)

            let checksum = header.reduce(0) { $0 + Int($1) }
            let checksumText = String(checksum, radix: 8)
            guard checksumText.count <= 6 else {
                throw PatchPackagingError.archiveFieldTooLong(entry.path)
            }
            let checksumField =
                String(repeating: "0", count: 6 - checksumText.count) + checksumText
            try write(checksumField, to: &header, offset: 148, width: 6)
            header[154] = 0
            header[155] = 0x20

            archive.append(contentsOf: header)
            archive.append(contents)
            appendPadding(to: &archive, multiple: blockSize)
        }
        archive.append(Data(repeating: 0, count: blockSize * 2))
        return archive
    }

    private static func write(
        _ value: String,
        to bytes: inout [UInt8],
        offset: Int,
        width: Int
    ) throws {
        let valueBytes = Array(value.utf8)
        guard valueBytes.count <= width else {
            throw PatchPackagingError.archiveFieldTooLong(value)
        }
        bytes.replaceSubrange(offset..<(offset + valueBytes.count), with: valueBytes)
    }

    private static func writeOctal(
        _ value: Int,
        to bytes: inout [UInt8],
        offset: Int,
        width: Int
    ) throws {
        let digits = String(value, radix: 8)
        guard digits.count <= width - 1 else {
            throw PatchPackagingError.archiveFieldTooLong(String(value))
        }
        let field = String(repeating: "0", count: width - 1 - digits.count) + digits
        try write(field, to: &bytes, offset: offset, width: width - 1)
        bytes[offset + width - 1] = 0
    }

    private static func appendPadding(to data: inout Data, multiple: Int) {
        let remainder = data.count % multiple
        if remainder != 0 {
            data.append(Data(repeating: 0, count: multiple - remainder))
        }
    }
}

struct ArMember {
    let name: String
    let contents: Data
}

enum ArArchiveWriter {
    static func encode(_ members: [ArMember]) throws -> Data {
        var archive = Data("!<arch>\n".utf8)
        for member in members {
            let archiveName = member.name.hasSuffix("/") ? member.name : "\(member.name)/"
            guard archiveName.utf8.count <= 16 else {
                throw PatchPackagingError.archiveFieldTooLong(member.name)
            }
            var header = Data()
            header.append(try field(archiveName, width: 16))
            header.append(try field("0", width: 12))
            header.append(try field("0", width: 6))
            header.append(try field("0", width: 6))
            header.append(try field("100644", width: 8))
            header.append(try field(String(member.contents.count), width: 10))
            header.append(Data("`\n".utf8))
            archive.append(header)
            archive.append(member.contents)
            if member.contents.count.isMultiple(of: 2) == false {
                archive.append(0x0A)
            }
        }
        return archive
    }

    private static func field(_ value: String, width: Int) throws -> Data {
        guard value.utf8.count <= width else {
            throw PatchPackagingError.archiveFieldTooLong(value)
        }
        return Data((value + String(repeating: " ", count: width - value.utf8.count)).utf8)
    }
}
