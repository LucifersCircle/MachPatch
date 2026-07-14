import Foundation

enum ZipArchiveValidator {
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localFileSignature: UInt32 = 0x0403_4B50
    private static let maximumEntryCount = 100_000
    private static let maximumCentralDirectorySize: UInt64 = 256 * 1_024 * 1_024
    private static let maximumExpandedSize: UInt64 = 32 * 1_024 * 1_024 * 1_024

    static func validateArchive(at archiveURL: URL) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archiveURL)
        } catch {
            throw ArchiveValidationError("archive cannot be opened: \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let endRecord = try findEndRecord(in: handle, fileSize: fileSize)

        guard endRecord.diskNumber == 0, endRecord.centralDirectoryDisk == 0 else {
            throw ArchiveValidationError("multi-disk ZIP archives are not supported")
        }
        guard endRecord.entriesOnDisk == endRecord.totalEntries else {
            throw ArchiveValidationError("central-directory entry counts do not match")
        }
        guard endRecord.totalEntries <= maximumEntryCount else {
            throw ArchiveValidationError("archive contains too many entries")
        }
        guard endRecord.centralDirectorySize <= maximumCentralDirectorySize else {
            throw ArchiveValidationError("central directory is unreasonably large")
        }

        let (centralEnd, overflow) = endRecord.centralDirectoryOffset.addingReportingOverflow(
            endRecord.centralDirectorySize
        )
        guard !overflow, centralEnd == endRecord.recordOffset, centralEnd <= fileSize else {
            throw ArchiveValidationError("central-directory bounds are invalid")
        }

        let centralDirectory = try readExactly(
            from: handle,
            offset: endRecord.centralDirectoryOffset,
            count: endRecord.centralDirectorySize
        )

        var cursor = 0
        var expandedSize: UInt64 = 0

        for _ in 0..<endRecord.totalEntries {
            guard centralDirectory.uint32LE(at: cursor) == centralDirectorySignature else {
                throw ArchiveValidationError("central-directory entry signature is invalid")
            }
            guard cursor + 46 <= centralDirectory.count else {
                throw ArchiveValidationError("central-directory entry is truncated")
            }

            let hostSystem = centralDirectory[cursor + 5]
            let flags = try centralDirectory.requiredUInt16LE(at: cursor + 8)
            let compressionMethod = try centralDirectory.requiredUInt16LE(at: cursor + 10)
            let rawCompressedSize = try centralDirectory.requiredUInt32LE(at: cursor + 20)
            let rawUncompressedSize = try centralDirectory.requiredUInt32LE(at: cursor + 24)
            let nameLength = Int(try centralDirectory.requiredUInt16LE(at: cursor + 28))
            let extraLength = Int(try centralDirectory.requiredUInt16LE(at: cursor + 30))
            let commentLength = Int(try centralDirectory.requiredUInt16LE(at: cursor + 32))
            let rawStartingDisk = try centralDirectory.requiredUInt16LE(at: cursor + 34)
            let externalAttributes = try centralDirectory.requiredUInt32LE(at: cursor + 38)
            let rawLocalHeaderOffset = try centralDirectory.requiredUInt32LE(at: cursor + 42)

            guard flags & 0x0001 == 0 else {
                throw ArchiveValidationError("encrypted ZIP entries are not supported")
            }
            guard compressionMethod == 0 || compressionMethod == 8 else {
                throw ArchiveValidationError(
                    "entry uses unsupported compression method \(compressionMethod)"
                )
            }
            let entryEnd = cursor + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, entryEnd <= centralDirectory.count else {
                throw ArchiveValidationError("central-directory entry has invalid lengths")
            }

            let nameData = centralDirectory.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let extraData = centralDirectory.subdata(
                in: (cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extraLength)
            )
            guard let entryName = String(data: nameData, encoding: .utf8) else {
                throw ArchiveValidationError("entry name is not valid UTF-8")
            }
            try validateEntryPath(entryName)

            let sizes = try resolveEntryValues(
                extraData: extraData,
                rawCompressedSize: rawCompressedSize,
                rawUncompressedSize: rawUncompressedSize,
                rawLocalHeaderOffset: rawLocalHeaderOffset,
                rawStartingDisk: rawStartingDisk
            )
            guard sizes.startingDisk == 0 else {
                throw ArchiveValidationError("entry references another ZIP disk: \(entryName)")
            }

            let unixMode = UInt16((externalAttributes >> 16) & 0xFFFF)
            let fileType = unixMode & 0xF000
            if fileType == 0xA000 {
                throw ArchiveValidationError("symbolic-link entry is not allowed: \(entryName)")
            }
            if hostSystem == 3, fileType != 0, fileType != 0x4000, fileType != 0x8000 {
                throw ArchiveValidationError("unsupported Unix file type: \(entryName)")
            }

            let (newExpandedSize, sizeOverflow) = expandedSize.addingReportingOverflow(
                sizes.uncompressedSize
            )
            guard !sizeOverflow, newExpandedSize <= maximumExpandedSize else {
                throw ArchiveValidationError("expanded archive is unreasonably large")
            }
            expandedSize = newExpandedSize

            try validateLocalHeader(
                in: handle,
                offset: sizes.localHeaderOffset,
                expectedName: nameData,
                compressedSize: sizes.compressedSize,
                centralDirectoryOffset: endRecord.centralDirectoryOffset
            )
            cursor = entryEnd
        }

        guard cursor == centralDirectory.count else {
            throw ArchiveValidationError("central directory contains unparsed data")
        }
    }

    static func validateEntryPath(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("\\") else {
            throw ArchiveValidationError("entry has an absolute path: \(name)")
        }
        guard !name.contains("\\"), !name.contains("\0") else {
            throw ArchiveValidationError("entry has an unsafe path separator: \(name)")
        }

        var components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.last?.isEmpty == true {
            components.removeLast()
        }
        guard !components.isEmpty else {
            throw ArchiveValidationError("entry path is empty")
        }
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ArchiveValidationError(
                "entry traverses outside the extraction directory: \(name)")
        }
        if let first = components.first, first.count >= 2,
            first[first.index(after: first.startIndex)] == ":"
        {
            throw ArchiveValidationError("entry has a drive-qualified path: \(name)")
        }
    }

    private static func findEndRecord(
        in handle: FileHandle,
        fileSize: UInt64
    ) throws -> EndRecord {
        let minimumSize: UInt64 = 22
        let maximumSearchSize: UInt64 = minimumSize + UInt64(UInt16.max)
        guard fileSize >= minimumSize else {
            throw ArchiveValidationError("archive is too small to contain a ZIP end record")
        }

        let searchSize = min(fileSize, maximumSearchSize)
        let searchOffset = fileSize - searchSize
        let tail = try readExactly(from: handle, offset: searchOffset, count: searchSize)

        for index in stride(from: tail.count - Int(minimumSize), through: 0, by: -1) {
            guard tail.uint32LE(at: index) == endOfCentralDirectorySignature else {
                continue
            }
            let commentLength = Int(try tail.requiredUInt16LE(at: index + 20))
            guard index + Int(minimumSize) + commentLength == tail.count else {
                continue
            }

            let diskNumber = try tail.requiredUInt16LE(at: index + 4)
            let centralDirectoryDisk = try tail.requiredUInt16LE(at: index + 6)
            let entriesOnDisk = try tail.requiredUInt16LE(at: index + 8)
            let totalEntries = try tail.requiredUInt16LE(at: index + 10)
            let centralDirectorySize = try tail.requiredUInt32LE(at: index + 12)
            let centralDirectoryOffset = try tail.requiredUInt32LE(at: index + 16)

            guard entriesOnDisk != UInt16.max,
                totalEntries != UInt16.max,
                centralDirectorySize != UInt32.max,
                centralDirectoryOffset != UInt32.max
            else {
                throw ArchiveValidationError("ZIP64 archives are not supported")
            }

            return EndRecord(
                diskNumber: diskNumber,
                centralDirectoryDisk: centralDirectoryDisk,
                entriesOnDisk: Int(entriesOnDisk),
                totalEntries: Int(totalEntries),
                centralDirectorySize: UInt64(centralDirectorySize),
                centralDirectoryOffset: UInt64(centralDirectoryOffset),
                recordOffset: searchOffset + UInt64(index)
            )
        }

        throw ArchiveValidationError("ZIP end record was not found")
    }

    private static func resolveEntryValues(
        extraData: Data,
        rawCompressedSize: UInt32,
        rawUncompressedSize: UInt32,
        rawLocalHeaderOffset: UInt32,
        rawStartingDisk: UInt16
    ) throws -> EntryValues {
        let requiresZip64 =
            rawCompressedSize == UInt32.max
            || rawUncompressedSize == UInt32.max
            || rawLocalHeaderOffset == UInt32.max
            || rawStartingDisk == UInt16.max

        guard requiresZip64 else {
            return EntryValues(
                compressedSize: UInt64(rawCompressedSize),
                uncompressedSize: UInt64(rawUncompressedSize),
                localHeaderOffset: UInt64(rawLocalHeaderOffset),
                startingDisk: UInt32(rawStartingDisk)
            )
        }

        var cursor = 0
        var zip64Data: Data?
        while cursor + 4 <= extraData.count {
            let identifier = try extraData.requiredUInt16LE(at: cursor)
            let fieldLength = Int(try extraData.requiredUInt16LE(at: cursor + 2))
            let fieldEnd = cursor + 4 + fieldLength
            guard fieldEnd <= extraData.count else {
                throw ArchiveValidationError("ZIP extra field is truncated")
            }
            if identifier == 0x0001 {
                zip64Data = extraData.subdata(in: (cursor + 4)..<fieldEnd)
                break
            }
            cursor = fieldEnd
        }

        guard let zip64Data else {
            throw ArchiveValidationError("ZIP64 values are missing from an entry")
        }

        var valueOffset = 0
        func nextUInt64() throws -> UInt64 {
            let value = try zip64Data.requiredUInt64LE(at: valueOffset)
            valueOffset += 8
            return value
        }
        func nextUInt32() throws -> UInt32 {
            let value = try zip64Data.requiredUInt32LE(at: valueOffset)
            valueOffset += 4
            return value
        }

        let uncompressedSize =
            try rawUncompressedSize == UInt32.max
            ? nextUInt64() : UInt64(rawUncompressedSize)
        let compressedSize =
            try rawCompressedSize == UInt32.max
            ? nextUInt64() : UInt64(rawCompressedSize)
        let localHeaderOffset =
            try rawLocalHeaderOffset == UInt32.max
            ? nextUInt64() : UInt64(rawLocalHeaderOffset)
        let startingDisk =
            try rawStartingDisk == UInt16.max
            ? nextUInt32() : UInt32(rawStartingDisk)

        return EntryValues(
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localHeaderOffset,
            startingDisk: startingDisk
        )
    }

    private static func validateLocalHeader(
        in handle: FileHandle,
        offset: UInt64,
        expectedName: Data,
        compressedSize: UInt64,
        centralDirectoryOffset: UInt64
    ) throws {
        let header = try readExactly(from: handle, offset: offset, count: 30)
        guard header.uint32LE(at: 0) == localFileSignature else {
            throw ArchiveValidationError("local file header signature is invalid")
        }

        let nameLength = UInt64(try header.requiredUInt16LE(at: 26))
        let extraLength = UInt64(try header.requiredUInt16LE(at: 28))
        let name = try readExactly(from: handle, offset: offset + 30, count: nameLength)
        guard name == expectedName else {
            throw ArchiveValidationError("local and central entry names do not match")
        }

        let (metadataEnd, metadataOverflow) = offset.addingReportingOverflow(
            30 + nameLength + extraLength
        )
        let (dataEnd, dataOverflow) = metadataEnd.addingReportingOverflow(compressedSize)
        guard !metadataOverflow, !dataOverflow, dataEnd <= centralDirectoryOffset else {
            throw ArchiveValidationError("local entry data extends beyond the central directory")
        }
    }

    private static func readExactly(
        from handle: FileHandle,
        offset: UInt64,
        count: UInt64
    ) throws -> Data {
        guard count <= UInt64(Int.max) else {
            throw ArchiveValidationError("requested archive range is too large")
        }
        try handle.seek(toOffset: offset)

        var result = Data()
        result.reserveCapacity(Int(count))
        while result.count < Int(count) {
            let remaining = Int(count) - result.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw ArchiveValidationError("archive data is truncated")
            }
            result.append(chunk)
        }
        return result
    }

    private struct EndRecord {
        let diskNumber: UInt16
        let centralDirectoryDisk: UInt16
        let entriesOnDisk: Int
        let totalEntries: Int
        let centralDirectorySize: UInt64
        let centralDirectoryOffset: UInt64
        let recordOffset: UInt64
    }

    private struct EntryValues {
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let startingDisk: UInt32
    }
}

struct ArchiveValidationError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func requiredUInt16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw ArchiveValidationError("archive integer field is truncated")
        }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func requiredUInt32LE(at offset: Int) throws -> UInt32 {
        guard let value = uint32LE(at: offset) else {
            throw ArchiveValidationError("archive integer field is truncated")
        }
        return value
    }

    func requiredUInt64LE(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= count else {
            throw ArchiveValidationError("archive integer field is truncated")
        }
        return UInt64(self[offset])
            | UInt64(self[offset + 1]) << 8
            | UInt64(self[offset + 2]) << 16
            | UInt64(self[offset + 3]) << 24
            | UInt64(self[offset + 4]) << 32
            | UInt64(self[offset + 5]) << 40
            | UInt64(self[offset + 6]) << 48
            | UInt64(self[offset + 7]) << 56
    }
}
