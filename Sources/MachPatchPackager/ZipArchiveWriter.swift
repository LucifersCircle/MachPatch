import Foundation

enum ZipArchiveWriter {
    private struct CentralEntry {
        let path: String
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
        let isExecutable: Bool
    }

    static func encode(_ files: [PackagedFile]) throws -> Data {
        guard files.count <= Int(UInt16.max) else {
            throw PatchPackagingError.archiveFieldTooLong("too many ZIP entries")
        }
        var archive = Data()
        var centralEntries: [CentralEntry] = []

        for file in files {
            let path = file.relativePath
            let pathData = Data(path.utf8)
            guard pathData.count <= Int(UInt16.max),
                file.contents.count <= Int(UInt32.max),
                archive.count <= Int(UInt32.max)
            else {
                throw PatchPackagingError.archiveFieldTooLong(path)
            }
            let crc32 = CRC32.checksum(file.contents)
            let size = UInt32(file.contents.count)
            let offset = UInt32(archive.count)

            archive.appendLittleEndian(UInt32(0x0403_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0x0021))
            archive.appendLittleEndian(crc32)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(UInt16(pathData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(pathData)
            archive.append(file.contents)

            centralEntries.append(
                CentralEntry(
                    path: path,
                    crc32: crc32,
                    size: size,
                    localHeaderOffset: offset,
                    isExecutable: file.isExecutable
                )
            )
        }

        guard archive.count <= Int(UInt32.max) else {
            throw PatchPackagingError.archiveFieldTooLong("ZIP local-file data")
        }
        let centralDirectoryOffset = UInt32(archive.count)
        for entry in centralEntries {
            let pathData = Data(entry.path.utf8)
            archive.appendLittleEndian(UInt32(0x0201_4B50))
            archive.appendLittleEndian(UInt16(0x0314))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0x0021))
            archive.appendLittleEndian(entry.crc32)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(UInt16(pathData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            let permissions: UInt32 = entry.isExecutable ? 0o100755 : 0o100644
            archive.appendLittleEndian(permissions << 16)
            archive.appendLittleEndian(entry.localHeaderOffset)
            archive.append(pathData)
        }

        guard archive.count <= Int(UInt32.max) else {
            throw PatchPackagingError.archiveFieldTooLong("ZIP central directory")
        }
        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset
        let entryCount = UInt16(centralEntries.count)
        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(centralDirectorySize)
        archive.appendLittleEndian(centralDirectoryOffset)
        archive.appendLittleEndian(UInt16(0))
        return archive
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
