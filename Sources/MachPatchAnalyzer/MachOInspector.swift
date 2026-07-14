import Foundation
import MachPatchCore

public struct MachOInspector: Sendable {
    private static let maximumSliceCount = 128
    private static let maximumLoadCommandBytes = 64 * 1_024 * 1_024
    private static let maximumLoadCommandCount = 65_535

    public init() {}

    public func inspect(_ target: ResolvedTarget) throws -> MachOInspection {
        MachOInspection(target: target, slices: try inspect(at: target.executableURL))
    }

    public func inspect(at executableURL: URL) throws -> [MachOSlice] {
        let data: Data
        do {
            data = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        } catch {
            throw MachOInspectionError.unreadableFile(error.localizedDescription)
        }

        guard data.count >= 4 else {
            throw MachOInspectionError.invalidMachO("file is smaller than a Mach-O magic value")
        }

        if let format = thinFormat(in: data, at: 0) {
            return [
                try parseThinSlice(
                    in: data,
                    offset: 0,
                    size: data.count,
                    index: 0,
                    format: format,
                    expectedCPU: nil
                )
            ]
        }
        if let format = fatFormat(in: data) {
            return try parseFatSlices(in: data, format: format)
        }
        throw MachOInspectionError.invalidMachO("unrecognized magic bytes")
    }

    private func parseFatSlices(in data: Data, format: FatFormat) throws -> [MachOSlice] {
        let reader = BinaryReader(data: data, endianness: format.endianness)
        let sliceCount = Int(try reader.uint32(at: 4))
        guard sliceCount > 0, sliceCount <= Self.maximumSliceCount else {
            throw MachOInspectionError.malformedMachO(
                "fat header declares unsupported slice count \(sliceCount)"
            )
        }

        let entrySize = format.is64Bit ? 32 : 20
        let (tableByteCount, tableOverflow) = sliceCount.multipliedReportingOverflow(by: entrySize)
        let (tableEnd, tableEndOverflow) = 8.addingReportingOverflow(tableByteCount)
        guard !tableOverflow, !tableEndOverflow, tableEnd <= data.count else {
            throw MachOInspectionError.malformedMachO("fat architecture table is truncated")
        }

        var records: [FatSliceRecord] = []
        records.reserveCapacity(sliceCount)

        for index in 0..<sliceCount {
            let recordOffset = 8 + index * entrySize
            let cpuType = Int32(bitPattern: try reader.uint32(at: recordOffset))
            let cpuSubtype = Int32(bitPattern: try reader.uint32(at: recordOffset + 4))
            let sliceOffset: UInt64
            let sliceSize: UInt64
            let alignmentExponent: UInt32

            if format.is64Bit {
                sliceOffset = try reader.uint64(at: recordOffset + 8)
                sliceSize = try reader.uint64(at: recordOffset + 16)
                alignmentExponent = try reader.uint32(at: recordOffset + 24)
            } else {
                sliceOffset = UInt64(try reader.uint32(at: recordOffset + 8))
                sliceSize = UInt64(try reader.uint32(at: recordOffset + 12))
                alignmentExponent = try reader.uint32(at: recordOffset + 16)
            }

            guard sliceSize > 0 else {
                throw MachOInspectionError.malformedMachO("fat slice \(index) has zero size")
            }
            guard alignmentExponent < 63 else {
                throw MachOInspectionError.malformedMachO(
                    "fat slice \(index) has invalid alignment exponent \(alignmentExponent)"
                )
            }
            let requiredAlignment = UInt64(1) << alignmentExponent
            guard sliceOffset % requiredAlignment == 0 else {
                throw MachOInspectionError.malformedMachO(
                    "fat slice \(index) offset does not satisfy its declared alignment"
                )
            }

            let (sliceEnd, sliceEndOverflow) = sliceOffset.addingReportingOverflow(sliceSize)
            guard !sliceEndOverflow,
                sliceOffset >= UInt64(tableEnd),
                sliceEnd <= UInt64(data.count),
                sliceOffset <= UInt64(Int.max),
                sliceSize <= UInt64(Int.max)
            else {
                throw MachOInspectionError.malformedMachO(
                    "fat slice \(index) lies outside the file"
                )
            }

            records.append(
                FatSliceRecord(
                    index: index,
                    cpuType: cpuType,
                    cpuSubtype: cpuSubtype,
                    offset: sliceOffset,
                    size: sliceSize
                )
            )
        }

        let sortedRecords = records.sorted { $0.offset < $1.offset }
        for pairIndex in 1..<sortedRecords.count {
            let previous = sortedRecords[pairIndex - 1]
            let current = sortedRecords[pairIndex]
            guard previous.offset + previous.size <= current.offset else {
                throw MachOInspectionError.malformedMachO("fat slices overlap")
            }
        }

        return try records.map { record in
            let offset = Int(record.offset)
            guard let thinFormat = thinFormat(in: data, at: offset) else {
                throw MachOInspectionError.malformedMachO(
                    "fat slice \(record.index) does not contain a thin Mach-O header"
                )
            }
            return try parseThinSlice(
                in: data,
                offset: offset,
                size: Int(record.size),
                index: record.index,
                format: thinFormat,
                expectedCPU: (record.cpuType, record.cpuSubtype)
            )
        }
    }

    private func parseThinSlice(
        in data: Data,
        offset: Int,
        size: Int,
        index: Int,
        format: ThinFormat,
        expectedCPU: (Int32, Int32)?
    ) throws -> MachOSlice {
        let reader = BinaryReader(data: data, endianness: format.endianness)
        let headerSize = format.is64Bit ? 32 : 28
        guard size >= headerSize, offset <= data.count - size else {
            throw MachOInspectionError.malformedMachO("slice \(index) header is truncated")
        }

        let cpuType = Int32(bitPattern: try reader.uint32(at: offset + 4))
        let cpuSubtype = Int32(bitPattern: try reader.uint32(at: offset + 8))
        let fileTypeValue = try reader.uint32(at: offset + 12)
        let loadCommandCount = Int(try reader.uint32(at: offset + 16))
        let loadCommandBytes = Int(try reader.uint32(at: offset + 20))

        if let expectedCPU,
            expectedCPU.0 != cpuType || expectedCPU.1 != cpuSubtype
        {
            throw MachOInspectionError.malformedMachO(
                "fat table CPU metadata does not match slice \(index)"
            )
        }
        guard loadCommandCount <= Self.maximumLoadCommandCount else {
            throw MachOInspectionError.malformedMachO(
                "slice \(index) declares too many load commands"
            )
        }
        guard loadCommandBytes <= Self.maximumLoadCommandBytes,
            loadCommandBytes <= size - headerSize
        else {
            throw MachOInspectionError.malformedMachO(
                "slice \(index) load-command region is invalid"
            )
        }

        let commandStart = offset + headerSize
        let commandEnd = commandStart + loadCommandBytes
        var commandOffset = commandStart
        var deployment: DeploymentRecord?
        var encryption: EncryptionRecord?
        var installName: String?
        var linkedLibraries: [LinkedLibrary] = []

        for commandIndex in 0..<loadCommandCount {
            guard commandOffset <= commandEnd - 8 else {
                throw MachOInspectionError.malformedMachO(
                    "slice \(index) load command \(commandIndex) is truncated"
                )
            }

            let command = try reader.uint32(at: commandOffset)
            let commandSize = Int(try reader.uint32(at: commandOffset + 4))
            let requiredAlignment = format.is64Bit ? 8 : 4
            guard commandSize >= 8,
                commandSize % requiredAlignment == 0,
                commandSize <= commandEnd - commandOffset
            else {
                throw MachOInspectionError.malformedMachO(
                    "slice \(index) load command \(commandIndex) has invalid size"
                )
            }

            switch command {
            case LoadCommand.buildVersion:
                guard commandSize >= 24 else {
                    throw invalidCommand("LC_BUILD_VERSION", slice: index)
                }
                let toolCount = Int(try reader.uint32(at: commandOffset + 20))
                let (toolBytes, toolOverflow) = toolCount.multipliedReportingOverflow(by: 8)
                guard !toolOverflow, 24 + toolBytes == commandSize else {
                    throw invalidCommand("LC_BUILD_VERSION tools", slice: index)
                }
                try setDeployment(
                    DeploymentRecord(
                        platform: platform(for: try reader.uint32(at: commandOffset + 8)),
                        platformValue: try reader.uint32(at: commandOffset + 8),
                        minimumVersion: versionString(
                            try reader.uint32(at: commandOffset + 12)
                        ),
                        sdkVersion: versionString(try reader.uint32(at: commandOffset + 16))
                    ),
                    current: &deployment,
                    slice: index
                )

            case LoadCommand.versionMinimumMacOS,
                LoadCommand.versionMinimumIPhoneOS,
                LoadCommand.versionMinimumTVOS,
                LoadCommand.versionMinimumWatchOS:
                guard commandSize == 16 else {
                    throw invalidCommand("version-minimum", slice: index)
                }
                let legacyPlatform = legacyPlatform(for: command)
                try setDeployment(
                    DeploymentRecord(
                        platform: legacyPlatform.0,
                        platformValue: legacyPlatform.1,
                        minimumVersion: versionString(
                            try reader.uint32(at: commandOffset + 8)
                        ),
                        sdkVersion: versionString(try reader.uint32(at: commandOffset + 12))
                    ),
                    current: &deployment,
                    slice: index
                )

            case LoadCommand.encryptionInfo, LoadCommand.encryptionInfo64:
                let expectedSize = command == LoadCommand.encryptionInfo64 ? 24 : 20
                guard commandSize == expectedSize, encryption == nil else {
                    throw invalidCommand("encryption-info", slice: index)
                }
                encryption = EncryptionRecord(
                    offset: try reader.uint32(at: commandOffset + 8),
                    size: try reader.uint32(at: commandOffset + 12),
                    cryptID: try reader.uint32(at: commandOffset + 16)
                )

            case LoadCommand.identifierDylib:
                let dylib = try parseDylibCommand(
                    reader: reader,
                    commandOffset: commandOffset,
                    commandSize: commandSize,
                    kind: nil,
                    slice: index
                )
                if let existingInstallName = installName, existingInstallName != dylib.path {
                    throw MachOInspectionError.malformedMachO(
                        "slice \(index) contains conflicting install names"
                    )
                }
                installName = dylib.path

            case LoadCommand.loadDylib,
                LoadCommand.loadWeakDylib,
                LoadCommand.reexportDylib,
                LoadCommand.loadUpwardDylib,
                LoadCommand.lazyLoadDylib:
                let dylib = try parseDylibCommand(
                    reader: reader,
                    commandOffset: commandOffset,
                    commandSize: commandSize,
                    kind: libraryKind(for: command),
                    slice: index
                )
                guard let linkedLibrary = dylib.linkedLibrary else {
                    throw invalidCommand("dylib kind", slice: index)
                }
                linkedLibraries.append(linkedLibrary)

            default:
                break
            }

            commandOffset += commandSize
        }

        guard commandOffset == commandEnd else {
            throw MachOInspectionError.malformedMachO(
                "slice \(index) load-command byte count does not match its header"
            )
        }

        if let encryption {
            let encryptedRegionEnd = UInt64(encryption.offset) + UInt64(encryption.size)
            guard encryptedRegionEnd <= UInt64(size) else {
                throw MachOInspectionError.malformedMachO(
                    "slice \(index) encryption range lies outside the slice"
                )
            }
        }

        let rawSubtype = UInt32(bitPattern: cpuSubtype)
        let subtypeBase = rawSubtype & 0x00FF_FFFF
        let subtypeCapabilities = rawSubtype & 0xFF00_0000

        return MachOSlice(
            index: index,
            architecture: architecture(cpuType: cpuType, subtypeBase: subtypeBase),
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            cpuSubtypeBase: subtypeBase,
            cpuSubtypeCapabilities: subtypeCapabilities,
            fileType: fileType(for: fileTypeValue),
            fileTypeValue: fileTypeValue,
            endianness: format.endianness,
            is64Bit: format.is64Bit,
            platform: deployment?.platform ?? .unknown,
            platformValue: deployment?.platformValue,
            minimumOSVersion: deployment?.minimumVersion,
            sdkVersion: deployment?.sdkVersion,
            encrypted: (encryption?.cryptID ?? 0) != 0,
            encryptionCryptID: encryption?.cryptID,
            encryptionOffset: encryption?.offset,
            encryptionSize: encryption?.size,
            fileOffset: UInt64(offset),
            fileSize: UInt64(size),
            installName: installName,
            linkedLibraries: linkedLibraries
        )
    }

    private func parseDylibCommand(
        reader: BinaryReader,
        commandOffset: Int,
        commandSize: Int,
        kind: LinkedLibraryKind?,
        slice: Int
    ) throws -> DylibRecord {
        guard commandSize >= 24 else {
            throw invalidCommand("dylib", slice: slice)
        }
        let nameOffset = Int(try reader.uint32(at: commandOffset + 8))
        guard nameOffset >= 24, nameOffset < commandSize else {
            throw invalidCommand("dylib name", slice: slice)
        }
        let path = try reader.nullTerminatedString(
            at: commandOffset + nameOffset,
            before: commandOffset + commandSize
        )
        guard !path.isEmpty else {
            throw invalidCommand("empty dylib name", slice: slice)
        }

        return DylibRecord(
            path: path,
            kind: kind,
            currentVersion: versionString(try reader.uint32(at: commandOffset + 16)),
            compatibilityVersion: versionString(try reader.uint32(at: commandOffset + 20))
        )
    }

    private func setDeployment(
        _ candidate: DeploymentRecord,
        current: inout DeploymentRecord?,
        slice: Int
    ) throws {
        if let current, current != candidate {
            throw MachOInspectionError.malformedMachO(
                "slice \(slice) contains conflicting deployment commands"
            )
        }
        current = candidate
    }

    private func invalidCommand(_ name: String, slice: Int) -> MachOInspectionError {
        .malformedMachO("slice \(slice) contains an invalid \(name) command")
    }

    private func thinFormat(in data: Data, at offset: Int) -> ThinFormat? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return switch Array(data[offset..<(offset + 4)]) {
        case [0xCE, 0xFA, 0xED, 0xFE]: ThinFormat(endianness: .little, is64Bit: false)
        case [0xFE, 0xED, 0xFA, 0xCE]: ThinFormat(endianness: .big, is64Bit: false)
        case [0xCF, 0xFA, 0xED, 0xFE]: ThinFormat(endianness: .little, is64Bit: true)
        case [0xFE, 0xED, 0xFA, 0xCF]: ThinFormat(endianness: .big, is64Bit: true)
        default: nil
        }
    }

    private func fatFormat(in data: Data) -> FatFormat? {
        switch Array(data[0..<4]) {
        case [0xCA, 0xFE, 0xBA, 0xBE]: FatFormat(endianness: .big, is64Bit: false)
        case [0xBE, 0xBA, 0xFE, 0xCA]: FatFormat(endianness: .little, is64Bit: false)
        case [0xCA, 0xFE, 0xBA, 0xBF]: FatFormat(endianness: .big, is64Bit: true)
        case [0xBF, 0xBA, 0xFE, 0xCA]: FatFormat(endianness: .little, is64Bit: true)
        default: nil
        }
    }

    private func architecture(cpuType: Int32, subtypeBase: UInt32) -> MachOArchitecture {
        switch UInt32(bitPattern: cpuType) {
        case 0x0100_000C:
            switch subtypeBase {
            case 0, 1: .arm64
            case 2: .arm64e
            default: .unknown
            }
        case 0x0200_000C:
            subtypeBase == 1 ? .arm6432 : .unknown
        case 0x0100_0007:
            .x8664
        case 0x0000_000C:
            switch subtypeBase {
            case 9: .armv7
            case 11: .armv7s
            default: .unknown
            }
        default:
            .unknown
        }
    }

    private func fileType(for value: UInt32) -> MachOFileType {
        switch value {
        case 1: .object
        case 2: .executable
        case 3: .fixedVMLibrary
        case 4: .core
        case 5: .preload
        case 6: .dynamicLibrary
        case 7: .dynamicLinker
        case 8: .bundle
        case 9: .dynamicLibraryStub
        case 10: .debugSymbols
        case 11: .kernelExtension
        case 12: .fileSet
        default: .unknown
        }
    }

    private func platform(for value: UInt32) -> MachOPlatform {
        switch value {
        case 1: .macOS
        case 2: .iPhoneOS
        case 3: .tvOS
        case 4: .watchOS
        case 5: .bridgeOS
        case 6: .macCatalyst
        case 7: .iPhoneSimulator
        case 8: .tvOSSimulator
        case 9: .watchOSSimulator
        case 10: .driverKit
        case 11: .visionOS
        case 12: .visionOSSimulator
        default: .unknown
        }
    }

    private func legacyPlatform(for command: UInt32) -> (MachOPlatform, UInt32) {
        switch command {
        case LoadCommand.versionMinimumMacOS: (.macOS, 1)
        case LoadCommand.versionMinimumIPhoneOS: (.iPhoneOS, 2)
        case LoadCommand.versionMinimumTVOS: (.tvOS, 3)
        case LoadCommand.versionMinimumWatchOS: (.watchOS, 4)
        default: (.unknown, 0)
        }
    }

    private func libraryKind(for command: UInt32) -> LinkedLibraryKind {
        switch command {
        case LoadCommand.loadWeakDylib: .weak
        case LoadCommand.reexportDylib: .reexport
        case LoadCommand.loadUpwardDylib: .upward
        case LoadCommand.lazyLoadDylib: .lazy
        default: .load
        }
    }

    private func versionString(_ value: UInt32) -> String {
        let major = value >> 16
        let minor = (value >> 8) & 0xFF
        let patch = value & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }
}

private enum LoadCommand {
    static let loadDylib: UInt32 = 0x0000_000C
    static let identifierDylib: UInt32 = 0x0000_000D
    static let loadWeakDylib: UInt32 = 0x8000_0018
    static let lazyLoadDylib: UInt32 = 0x0000_0020
    static let encryptionInfo: UInt32 = 0x0000_0021
    static let versionMinimumMacOS: UInt32 = 0x0000_0024
    static let versionMinimumIPhoneOS: UInt32 = 0x0000_0025
    static let encryptionInfo64: UInt32 = 0x0000_002C
    static let versionMinimumTVOS: UInt32 = 0x0000_002F
    static let versionMinimumWatchOS: UInt32 = 0x0000_0030
    static let buildVersion: UInt32 = 0x0000_0032
    static let reexportDylib: UInt32 = 0x8000_001F
    static let loadUpwardDylib: UInt32 = 0x8000_0023
}

private struct ThinFormat {
    let endianness: MachOEndianness
    let is64Bit: Bool
}

private struct FatFormat {
    let endianness: MachOEndianness
    let is64Bit: Bool
}

private struct FatSliceRecord {
    let index: Int
    let cpuType: Int32
    let cpuSubtype: Int32
    let offset: UInt64
    let size: UInt64
}

private struct DeploymentRecord: Equatable {
    let platform: MachOPlatform
    let platformValue: UInt32
    let minimumVersion: String
    let sdkVersion: String
}

private struct EncryptionRecord {
    let offset: UInt32
    let size: UInt32
    let cryptID: UInt32
}

private struct DylibRecord {
    let path: String
    let kind: LinkedLibraryKind?
    let currentVersion: String
    let compatibilityVersion: String

    var linkedLibrary: LinkedLibrary? {
        guard let kind else { return nil }
        return LinkedLibrary(
            path: path,
            kind: kind,
            currentVersion: currentVersion,
            compatibilityVersion: compatibilityVersion
        )
    }
}

private struct BinaryReader {
    let data: Data
    let endianness: MachOEndianness

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw MachOInspectionError.malformedMachO("32-bit integer extends beyond the file")
        }
        let bytes = data
        return switch endianness {
        case .little:
            UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        case .big:
            UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
    }

    func uint64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else {
            throw MachOInspectionError.malformedMachO("64-bit integer extends beyond the file")
        }
        let bytes = data
        return switch endianness {
        case .little:
            UInt64(bytes[offset])
                | UInt64(bytes[offset + 1]) << 8
                | UInt64(bytes[offset + 2]) << 16
                | UInt64(bytes[offset + 3]) << 24
                | UInt64(bytes[offset + 4]) << 32
                | UInt64(bytes[offset + 5]) << 40
                | UInt64(bytes[offset + 6]) << 48
                | UInt64(bytes[offset + 7]) << 56
        case .big:
            UInt64(bytes[offset]) << 56
                | UInt64(bytes[offset + 1]) << 48
                | UInt64(bytes[offset + 2]) << 40
                | UInt64(bytes[offset + 3]) << 32
                | UInt64(bytes[offset + 4]) << 24
                | UInt64(bytes[offset + 5]) << 16
                | UInt64(bytes[offset + 6]) << 8
                | UInt64(bytes[offset + 7])
        }
    }

    func nullTerminatedString(at offset: Int, before end: Int) throws -> String {
        guard offset >= 0, offset < end, end <= data.count else {
            throw MachOInspectionError.malformedMachO("string bounds are invalid")
        }
        var terminator = offset
        while terminator < end, data[terminator] != 0 {
            terminator += 1
        }
        guard terminator < end else {
            throw MachOInspectionError.malformedMachO("string is not null-terminated")
        }
        guard let string = String(data: data[offset..<terminator], encoding: .utf8) else {
            throw MachOInspectionError.malformedMachO("string is not valid UTF-8")
        }
        return string
    }
}
