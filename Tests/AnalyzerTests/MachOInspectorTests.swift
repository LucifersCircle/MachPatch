import Foundation
import MachPatchCore
import XCTest

@testable import MachPatchAnalyzer

final class MachOInspectorTests: XCTestCase {
    func testInspectsThinArm64DeviceExecutable() throws {
        let data = MachOFixtureFactory.thin64(
            cryptID: 1,
            libraries: [
                .load(
                    "/usr/lib/libSystem.B.dylib",
                    currentVersion: MachOFixtureFactory.packedVersion(1356, 0)
                ),
                .weak(
                    "/System/Library/Frameworks/SwiftUI.framework/SwiftUI",
                    currentVersion: MachOFixtureFactory.packedVersion(7, 0, 84)
                ),
            ]
        )

        let slice = try inspectSingleSlice(data)
        XCTAssertEqual(slice.index, 0)
        XCTAssertEqual(slice.architecture, .arm64)
        XCTAssertEqual(slice.cpuType, Int32(bitPattern: MachOFixtureFactory.cpuTypeARM64))
        XCTAssertEqual(slice.cpuSubtype, 0)
        XCTAssertEqual(slice.cpuSubtypeBase, 0)
        XCTAssertEqual(slice.cpuSubtypeCapabilities, 0)
        XCTAssertEqual(slice.fileType, .executable)
        XCTAssertEqual(slice.fileTypeValue, 2)
        XCTAssertEqual(slice.endianness, .little)
        XCTAssertTrue(slice.is64Bit)
        XCTAssertEqual(slice.platform, .iPhoneOS)
        XCTAssertEqual(slice.platformValue, 2)
        XCTAssertEqual(slice.minimumOSVersion, "15.0")
        XCTAssertEqual(slice.sdkVersion, "17.2")
        XCTAssertTrue(slice.encrypted)
        XCTAssertEqual(slice.encryptionCryptID, 1)
        XCTAssertEqual(slice.encryptionOffset, 0x200)
        XCTAssertEqual(slice.encryptionSize, 0x40)
        XCTAssertEqual(slice.fileOffset, 0)
        XCTAssertEqual(slice.fileSize, UInt64(data.count))
        XCTAssertEqual(slice.linkedLibraries.count, 2)
        XCTAssertEqual(slice.linkedLibraries[0].kind, .load)
        XCTAssertEqual(slice.linkedLibraries[0].path, "/usr/lib/libSystem.B.dylib")
        XCTAssertEqual(slice.linkedLibraries[0].currentVersion, "1356.0")
        XCTAssertEqual(slice.linkedLibraries[1].kind, .weak)
        XCTAssertEqual(slice.linkedLibraries[1].currentVersion, "7.0.84")
    }

    func testDistinguishesArm64DeviceAndSimulatorFromPlatformMetadata() throws {
        let device = try inspectSingleSlice(MachOFixtureFactory.thin64(platform: 2, cryptID: nil))
        let simulator = try inspectSingleSlice(
            MachOFixtureFactory.thin64(platform: 7, cryptID: nil)
        )

        XCTAssertEqual(device.architecture, .arm64)
        XCTAssertEqual(simulator.architecture, .arm64)
        XCTAssertEqual(device.platform, .iPhoneOS)
        XCTAssertEqual(simulator.platform, .iPhoneSimulator)
        XCTAssertEqual(device.platformValue, 2)
        XCTAssertEqual(simulator.platformValue, 7)
    }

    func testPreservesArm64eSubtypeCapabilities() throws {
        let rawSubtype: UInt32 = 0x8000_0002
        let slice = try inspectSingleSlice(
            MachOFixtureFactory.thin64(cpuSubtype: rawSubtype, cryptID: nil)
        )

        XCTAssertEqual(slice.architecture, .arm64e)
        XCTAssertEqual(slice.cpuSubtype, Int32(bitPattern: rawSubtype))
        XCTAssertEqual(slice.cpuSubtypeBase, 2)
        XCTAssertEqual(slice.cpuSubtypeCapabilities, 0x8000_0000)
    }

    func testInspectsEveryFatSlice() throws {
        let arm64 = MachOFixtureFactory.thin64(cpuSubtype: 0, cryptID: 0)
        let arm64e = MachOFixtureFactory.thin64(cpuSubtype: 2, cryptID: 0)
        let fat = MachOFixtureFactory.fat32(slices: [
            (MachOFixtureFactory.cpuTypeARM64, 0, arm64),
            (MachOFixtureFactory.cpuTypeARM64, 2, arm64e),
        ])

        let slices = try inspect(fat)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices.map(\.index), [0, 1])
        XCTAssertEqual(slices.map(\.architecture), [.arm64, .arm64e])
        XCTAssertEqual(slices.map(\.cpuSubtype), [0, 2])
        XCTAssertGreaterThan(slices[0].fileOffset, 0)
        XCTAssertGreaterThan(slices[1].fileOffset, slices[0].fileOffset)
        XCTAssertEqual(slices[0].fileSize, UInt64(arm64.count))
        XCTAssertEqual(slices[1].fileSize, UInt64(arm64e.count))
    }

    func testParsesLegacyVersionCommandsAndBigEndian32BitHeaders() throws {
        let slice = try inspectSingleSlice(MachOFixtureFactory.thin32BigEndianARMv7())

        XCTAssertEqual(slice.architecture, .armv7)
        XCTAssertEqual(slice.endianness, .big)
        XCTAssertFalse(slice.is64Bit)
        XCTAssertEqual(slice.platform, .iPhoneOS)
        XCTAssertEqual(slice.minimumOSVersion, "12.4")
        XCTAssertEqual(slice.sdkVersion, "14.1")
        XCTAssertFalse(slice.encrypted)
        XCTAssertEqual(slice.encryptionCryptID, 0)
    }

    func testPreservesUnknownCPUAndPlatformValues() throws {
        let slice = try inspectSingleSlice(
            MachOFixtureFactory.thin64(
                cpuType: 0x1234_5678,
                cpuSubtype: 0x0100_002A,
                platform: 99,
                cryptID: nil
            )
        )

        XCTAssertEqual(slice.architecture, .unknown)
        XCTAssertEqual(slice.cpuType, Int32(bitPattern: 0x1234_5678))
        XCTAssertEqual(slice.cpuSubtype, Int32(bitPattern: 0x0100_002A))
        XCTAssertEqual(slice.cpuSubtypeBase, 42)
        XCTAssertEqual(slice.cpuSubtypeCapabilities, 0x0100_0000)
        XCTAssertEqual(slice.platform, .unknown)
        XCTAssertEqual(slice.platformValue, 99)
    }

    func testParsesDylibInstallName() throws {
        let slice = try inspectSingleSlice(
            MachOFixtureFactory.thin64(
                fileType: 6,
                cryptID: nil,
                installName: "@rpath/Fixture.dylib"
            )
        )

        XCTAssertEqual(slice.fileType, .dynamicLibrary)
        XCTAssertEqual(slice.installName, "@rpath/Fixture.dylib")
    }

    func testRejectsFatSliceOutsideFile() throws {
        var malformed = Data([0xCA, 0xFE, 0xBA, 0xBE])
        malformed.appendUInt32(1, endianness: .big)
        malformed.appendUInt32(MachOFixtureFactory.cpuTypeARM64, endianness: .big)
        malformed.appendUInt32(0, endianness: .big)
        malformed.appendUInt32(0x1000, endianness: .big)
        malformed.appendUInt32(0x200, endianness: .big)
        malformed.appendUInt32(12, endianness: .big)

        XCTAssertThrowsError(try inspect(malformed)) { error in
            guard case .malformedMachO = error as? MachOInspectionError else {
                return XCTFail("Expected malformedMachO, received \(error)")
            }
        }
    }

    func testRejectsInvalidLoadCommandSize() throws {
        var malformed = MachOFixtureFactory.thin64(cryptID: nil)
        malformed.replaceUInt32(at: 36, with: 4, endianness: .little)

        XCTAssertThrowsError(try inspect(malformed)) { error in
            guard case .malformedMachO = error as? MachOInspectionError else {
                return XCTFail("Expected malformedMachO, received \(error)")
            }
        }
    }

    func testRejectsEncryptionRangeOutsideSlice() throws {
        var malformed = MachOFixtureFactory.thin64(cryptID: 1)
        malformed.replaceUInt32(at: 64, with: UInt32.max, endianness: .little)

        XCTAssertThrowsError(try inspect(malformed)) { error in
            guard case .malformedMachO = error as? MachOInspectionError else {
                return XCTFail("Expected malformedMachO, received \(error)")
            }
        }
    }

    private func inspectSingleSlice(_ data: Data) throws -> MachOSlice {
        let slices = try inspect(data)
        return try XCTUnwrap(slices.first)
    }

    private func inspect(_ data: Data) throws -> [MachOSlice] {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-MachOFixture-\(UUID().uuidString)"
        )
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try MachOInspector().inspect(at: url)
    }
}
