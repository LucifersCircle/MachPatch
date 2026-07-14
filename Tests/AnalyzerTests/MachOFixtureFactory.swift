import Foundation

enum MachOFixtureFactory {
    static let cpuTypeARM: UInt32 = 0x0000_000C
    static let cpuTypeARM64: UInt32 = 0x0100_000C

    struct LibrarySpec {
        let command: UInt32
        let path: String
        let currentVersion: UInt32
        let compatibilityVersion: UInt32

        static func load(
            _ path: String,
            currentVersion: UInt32 = 0x0001_0000,
            compatibilityVersion: UInt32 = 0x0001_0000
        ) -> LibrarySpec {
            LibrarySpec(
                command: 0x0000_000C,
                path: path,
                currentVersion: currentVersion,
                compatibilityVersion: compatibilityVersion
            )
        }

        static func weak(
            _ path: String,
            currentVersion: UInt32 = 0x0001_0000,
            compatibilityVersion: UInt32 = 0x0001_0000
        ) -> LibrarySpec {
            LibrarySpec(
                command: 0x8000_0018,
                path: path,
                currentVersion: currentVersion,
                compatibilityVersion: compatibilityVersion
            )
        }
    }

    static func thin64(
        cpuType: UInt32 = cpuTypeARM64,
        cpuSubtype: UInt32 = 0,
        fileType: UInt32 = 2,
        platform: UInt32? = 2,
        minimumVersion: UInt32 = packedVersion(15, 0),
        sdkVersion: UInt32 = packedVersion(17, 2),
        cryptID: UInt32? = 0,
        installName: String? = nil,
        libraries: [LibrarySpec] = []
    ) -> Data {
        var commands: [Data] = []
        if let platform {
            commands.append(
                buildVersionCommand(
                    platform: platform,
                    minimumVersion: minimumVersion,
                    sdkVersion: sdkVersion,
                    endianness: .little
                )
            )
        }
        if let cryptID {
            commands.append(
                encryptionCommand64(
                    offset: 0x200,
                    size: 0x40,
                    cryptID: cryptID,
                    endianness: .little
                )
            )
        }
        if let installName {
            commands.append(
                dylibCommand(
                    command: 0x0000_000D,
                    path: installName,
                    currentVersion: packedVersion(1, 2, 3),
                    compatibilityVersion: packedVersion(1, 0),
                    endianness: .little,
                    alignment: 8
                )
            )
        }
        commands.append(
            contentsOf: libraries.map {
                dylibCommand(
                    command: $0.command,
                    path: $0.path,
                    currentVersion: $0.currentVersion,
                    compatibilityVersion: $0.compatibilityVersion,
                    endianness: .little,
                    alignment: 8
                )
            }
        )

        let commandBytes = commands.reduce(0) { $0 + $1.count }
        var data = Data([0xCF, 0xFA, 0xED, 0xFE])
        data.appendUInt32(cpuType, endianness: .little)
        data.appendUInt32(cpuSubtype, endianness: .little)
        data.appendUInt32(fileType, endianness: .little)
        data.appendUInt32(UInt32(commands.count), endianness: .little)
        data.appendUInt32(UInt32(commandBytes), endianness: .little)
        data.appendUInt32(0, endianness: .little)
        data.appendUInt32(0, endianness: .little)
        commands.forEach { data.append($0) }

        if cryptID != nil, data.count < 0x240 {
            data.append(Data(count: 0x240 - data.count))
        }
        return data
    }

    static func thin32BigEndianARMv7() -> Data {
        let deployment = legacyVersionCommand(
            command: 0x0000_0025,
            minimumVersion: packedVersion(12, 4),
            sdkVersion: packedVersion(14, 1),
            endianness: .big
        )
        let encryption = encryptionCommand32(
            offset: 0x100,
            size: 0x20,
            cryptID: 0,
            endianness: .big
        )
        let commands = [deployment, encryption]
        let commandBytes = commands.reduce(0) { $0 + $1.count }

        var data = Data([0xFE, 0xED, 0xFA, 0xCE])
        data.appendUInt32(cpuTypeARM, endianness: .big)
        data.appendUInt32(9, endianness: .big)
        data.appendUInt32(2, endianness: .big)
        data.appendUInt32(UInt32(commands.count), endianness: .big)
        data.appendUInt32(UInt32(commandBytes), endianness: .big)
        data.appendUInt32(0, endianness: .big)
        commands.forEach { data.append($0) }
        if data.count < 0x120 {
            data.append(Data(count: 0x120 - data.count))
        }
        return data
    }

    static func fat32(
        slices: [(cpuType: UInt32, cpuSubtype: UInt32, data: Data)]
    ) -> Data {
        let alignmentExponent: UInt32 = 12
        let alignment = 1 << Int(alignmentExponent)
        let tableEnd = 8 + slices.count * 20
        var offsets: [Int] = []
        var nextOffset = roundUp(tableEnd, alignment: alignment)

        for slice in slices {
            offsets.append(nextOffset)
            nextOffset = roundUp(nextOffset + slice.data.count, alignment: alignment)
        }

        var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
        data.appendUInt32(UInt32(slices.count), endianness: .big)
        for (index, slice) in slices.enumerated() {
            data.appendUInt32(slice.cpuType, endianness: .big)
            data.appendUInt32(slice.cpuSubtype, endianness: .big)
            data.appendUInt32(UInt32(offsets[index]), endianness: .big)
            data.appendUInt32(UInt32(slice.data.count), endianness: .big)
            data.appendUInt32(alignmentExponent, endianness: .big)
        }

        for (index, slice) in slices.enumerated() {
            if data.count < offsets[index] {
                data.append(Data(count: offsets[index] - data.count))
            }
            data.append(slice.data)
        }
        return data
    }

    static func packedVersion(_ major: UInt32, _ minor: UInt32, _ patch: UInt32 = 0) -> UInt32 {
        major << 16 | minor << 8 | patch
    }

    private static func buildVersionCommand(
        platform: UInt32,
        minimumVersion: UInt32,
        sdkVersion: UInt32,
        endianness: FixtureEndianness
    ) -> Data {
        var data = Data()
        data.appendUInt32(0x0000_0032, endianness: endianness)
        data.appendUInt32(24, endianness: endianness)
        data.appendUInt32(platform, endianness: endianness)
        data.appendUInt32(minimumVersion, endianness: endianness)
        data.appendUInt32(sdkVersion, endianness: endianness)
        data.appendUInt32(0, endianness: endianness)
        return data
    }

    private static func legacyVersionCommand(
        command: UInt32,
        minimumVersion: UInt32,
        sdkVersion: UInt32,
        endianness: FixtureEndianness
    ) -> Data {
        var data = Data()
        data.appendUInt32(command, endianness: endianness)
        data.appendUInt32(16, endianness: endianness)
        data.appendUInt32(minimumVersion, endianness: endianness)
        data.appendUInt32(sdkVersion, endianness: endianness)
        return data
    }

    private static func encryptionCommand64(
        offset: UInt32,
        size: UInt32,
        cryptID: UInt32,
        endianness: FixtureEndianness
    ) -> Data {
        var data = encryptionCommand32(
            offset: offset,
            size: size,
            cryptID: cryptID,
            endianness: endianness
        )
        data.replaceUInt32(at: 0, with: 0x0000_002C, endianness: endianness)
        data.replaceUInt32(at: 4, with: 24, endianness: endianness)
        data.appendUInt32(0, endianness: endianness)
        return data
    }

    private static func encryptionCommand32(
        offset: UInt32,
        size: UInt32,
        cryptID: UInt32,
        endianness: FixtureEndianness
    ) -> Data {
        var data = Data()
        data.appendUInt32(0x0000_0021, endianness: endianness)
        data.appendUInt32(20, endianness: endianness)
        data.appendUInt32(offset, endianness: endianness)
        data.appendUInt32(size, endianness: endianness)
        data.appendUInt32(cryptID, endianness: endianness)
        return data
    }

    private static func dylibCommand(
        command: UInt32,
        path: String,
        currentVersion: UInt32,
        compatibilityVersion: UInt32,
        endianness: FixtureEndianness,
        alignment: Int
    ) -> Data {
        var pathData = Data(path.utf8)
        pathData.append(0)
        let commandSize = roundUp(24 + pathData.count, alignment: alignment)

        var data = Data()
        data.appendUInt32(command, endianness: endianness)
        data.appendUInt32(UInt32(commandSize), endianness: endianness)
        data.appendUInt32(24, endianness: endianness)
        data.appendUInt32(0, endianness: endianness)
        data.appendUInt32(currentVersion, endianness: endianness)
        data.appendUInt32(compatibilityVersion, endianness: endianness)
        data.append(pathData)
        data.append(Data(count: commandSize - data.count))
        return data
    }

    private static func roundUp(_ value: Int, alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}

enum FixtureEndianness {
    case little
    case big
}

extension Data {
    mutating func appendUInt32(_ value: UInt32, endianness: FixtureEndianness) {
        let bytes: [UInt8]
        switch endianness {
        case .little:
            bytes = [
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 24),
            ]
        case .big:
            bytes = [
                UInt8(truncatingIfNeeded: value >> 24),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value),
            ]
        }
        append(contentsOf: bytes)
    }

    mutating func replaceUInt32(
        at offset: Int,
        with value: UInt32,
        endianness: FixtureEndianness
    ) {
        var replacement = Data()
        replacement.appendUInt32(value, endianness: endianness)
        replaceSubrange(offset..<(offset + 4), with: replacement)
    }
}
