import Foundation

public struct MachOInspection: Codable, Equatable, Sendable {
    public let target: ResolvedTarget
    public let image: ResolvedImage
    public let slices: [MachOSlice]

    public init(
        target: ResolvedTarget,
        image: ResolvedImage? = nil,
        slices: [MachOSlice]
    ) {
        self.target = target
        self.image = image ?? target.primaryImage
        self.slices = slices
    }
}

public struct MachOSlice: Codable, Equatable, Sendable {
    public let index: Int
    public let architecture: MachOArchitecture
    public let cpuType: Int32
    public let cpuSubtype: Int32
    public let cpuSubtypeBase: UInt32
    public let cpuSubtypeCapabilities: UInt32
    public let fileType: MachOFileType
    public let fileTypeValue: UInt32
    public let endianness: MachOEndianness
    public let is64Bit: Bool
    public let platform: MachOPlatform
    public let platformValue: UInt32?
    public let minimumOSVersion: String?
    public let sdkVersion: String?
    public let encrypted: Bool
    public let encryptionCryptID: UInt32?
    public let encryptionOffset: UInt32?
    public let encryptionSize: UInt32?
    public let fileOffset: UInt64
    public let fileSize: UInt64
    public let installName: String?
    public let linkedLibraries: [LinkedLibrary]

    public init(
        index: Int,
        architecture: MachOArchitecture,
        cpuType: Int32,
        cpuSubtype: Int32,
        cpuSubtypeBase: UInt32,
        cpuSubtypeCapabilities: UInt32,
        fileType: MachOFileType,
        fileTypeValue: UInt32,
        endianness: MachOEndianness,
        is64Bit: Bool,
        platform: MachOPlatform,
        platformValue: UInt32?,
        minimumOSVersion: String?,
        sdkVersion: String?,
        encrypted: Bool,
        encryptionCryptID: UInt32?,
        encryptionOffset: UInt32?,
        encryptionSize: UInt32?,
        fileOffset: UInt64,
        fileSize: UInt64,
        installName: String?,
        linkedLibraries: [LinkedLibrary]
    ) {
        self.index = index
        self.architecture = architecture
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.cpuSubtypeBase = cpuSubtypeBase
        self.cpuSubtypeCapabilities = cpuSubtypeCapabilities
        self.fileType = fileType
        self.fileTypeValue = fileTypeValue
        self.endianness = endianness
        self.is64Bit = is64Bit
        self.platform = platform
        self.platformValue = platformValue
        self.minimumOSVersion = minimumOSVersion
        self.sdkVersion = sdkVersion
        self.encrypted = encrypted
        self.encryptionCryptID = encryptionCryptID
        self.encryptionOffset = encryptionOffset
        self.encryptionSize = encryptionSize
        self.fileOffset = fileOffset
        self.fileSize = fileSize
        self.installName = installName
        self.linkedLibraries = linkedLibraries
    }
}

public enum MachOArchitecture: String, Codable, Equatable, Hashable, Sendable {
    case arm64
    case arm64e
    case arm64eLegacy
    case arm6432 = "arm64_32"
    case armv7
    case armv7s
    case x8664 = "x86_64"
    case unknown
}

public enum MachOFileType: String, Codable, Equatable, Sendable {
    case object
    case executable
    case fixedVMLibrary
    case core
    case preload
    case dynamicLibrary
    case dynamicLinker
    case bundle
    case dynamicLibraryStub
    case debugSymbols
    case kernelExtension
    case fileSet
    case unknown
}

public enum MachOEndianness: String, Codable, Equatable, Sendable {
    case little
    case big
}

public enum MachOPlatform: String, Codable, Equatable, Sendable {
    case macOS
    case iPhoneOS
    case tvOS
    case watchOS
    case bridgeOS
    case macCatalyst
    case iPhoneSimulator
    case tvOSSimulator
    case watchOSSimulator
    case driverKit
    case visionOS
    case visionOSSimulator
    case unknown
}

public struct LinkedLibrary: Codable, Equatable, Sendable {
    public let path: String
    public let kind: LinkedLibraryKind
    public let currentVersion: String
    public let compatibilityVersion: String

    public init(
        path: String,
        kind: LinkedLibraryKind,
        currentVersion: String,
        compatibilityVersion: String
    ) {
        self.path = path
        self.kind = kind
        self.currentVersion = currentVersion
        self.compatibilityVersion = compatibilityVersion
    }
}

public enum LinkedLibraryKind: String, Codable, Equatable, Sendable {
    case load
    case weak
    case reexport
    case upward
    case lazy
}
