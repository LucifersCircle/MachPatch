import MachPatchCore
import XCTest

@testable import MachPatchBuilder

final class ArchitectureResolverTests: XCTestCase {
    func testAutomaticExplainsOrdinaryArm64Selection() throws {
        let resolution = try ArchitectureResolver.resolve(
            mode: .automatic,
            selectedSlice: PatchSelectedSlice(architecture: .arm64, cpuSubtype: 0)
        )

        XCTAssertEqual(resolution.outputArchitecture, .arm64)
        XCTAssertEqual(resolution.slices, [.arm64])
        XCTAssertTrue(resolution.reason.contains("recorded target slice is ordinary arm64"))
    }

    func testAutomaticSelectsOnlyVersionedArm64e() throws {
        let rawSubtype = Int32(bitPattern: 0x8300_0002)
        let resolution = try ArchitectureResolver.resolve(
            mode: .automatic,
            selectedSlice: PatchSelectedSlice(
                architecture: .arm64e,
                cpuSubtype: rawSubtype
            )
        )

        XCTAssertEqual(resolution.outputArchitecture, .arm64e)
        XCTAssertEqual(resolution.slices, [.arm64e])
        XCTAssertEqual(
            resolution.targetArm64eABI,
            Arm64eABI(generation: .versioned, pointerAuthenticationVersion: 3)
        )
    }

    func testLegacyAndInconsistentArm64eAreBlocked() {
        XCTAssertThrowsError(
            try ArchitectureResolver.resolve(
                mode: .automatic,
                selectedSlice: PatchSelectedSlice(
                    architecture: .arm64eLegacy,
                    cpuSubtype: 2
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchitectureResolutionError,
                .legacyArm64eUnsupported(2)
            )
        }
        XCTAssertThrowsError(
            try ArchitectureResolver.resolve(
                mode: .arm64e,
                selectedSlice: PatchSelectedSlice(architecture: .arm64e, cpuSubtype: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchitectureResolutionError,
                .legacyArm64eUnsupported(2)
            )
        }
    }

    func testExplicitModesCannotRelabelTargetArchitecture() {
        XCTAssertThrowsError(
            try ArchitectureResolver.resolve(
                mode: .arm64e,
                selectedSlice: PatchSelectedSlice(architecture: .arm64, cpuSubtype: 0)
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchitectureResolutionError,
                .modeIncompatibleWithTarget(.arm64e, .arm64)
            )
        }
        XCTAssertThrowsError(
            try ArchitectureResolver.resolve(
                mode: .arm64,
                selectedSlice: PatchSelectedSlice(
                    architecture: .arm64e,
                    cpuSubtype: Int32(bitPattern: 0x8000_0002)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchitectureResolutionError,
                .modeIncompatibleWithTarget(.arm64, .arm64e)
            )
        }
    }

    func testUniversalRequestsSeparateSlicesInStableOrder() throws {
        let resolution = try ArchitectureResolver.resolve(
            mode: .universal,
            selectedSlice: PatchSelectedSlice(architecture: .arm64, cpuSubtype: 0)
        )

        XCTAssertEqual(resolution.outputArchitecture, .universal)
        XCTAssertEqual(resolution.slices, [.arm64, .arm64e])
        XCTAssertTrue(resolution.reason.contains("both must pass"))
    }

    func testTargetReportRejectsSimulatorAndLegacySlices() {
        let report = ArchitectureResolver.report(for: [
            makeSlice(index: 0, architecture: .arm64, subtype: 0, platform: .iPhoneOS),
            makeSlice(
                index: 1,
                architecture: .arm64e,
                subtype: Int32(bitPattern: 0x8000_0002),
                platform: .iPhoneOS
            ),
            makeSlice(index: 2, architecture: .arm64eLegacy, subtype: 2, platform: .iPhoneOS),
            makeSlice(index: 3, architecture: .arm64, subtype: 0, platform: .iPhoneSimulator),
        ])

        XCTAssertEqual(report.availableModes, [.automatic, .arm64, .arm64e, .universal])
        XCTAssertNil(report.automaticRecommendation)
        XCTAssertTrue(report.automaticReason.contains("selected slice determines"))
        XCTAssertEqual(report.slices.map(\.supportedForPatching), [true, true, false, false])
        XCTAssertEqual(
            report.slices[1].arm64eABI,
            Arm64eABI(generation: .versioned, pointerAuthenticationVersion: 0)
        )
        XCTAssertTrue(report.slices[2].diagnostic.contains("Legacy unversioned"))
        XCTAssertTrue(report.slices[3].diagnostic.contains("Unsupported platform"))
    }

    private func makeSlice(
        index: Int,
        architecture: MachOArchitecture,
        subtype: Int32,
        platform: MachOPlatform
    ) -> MachOSlice {
        let raw = UInt32(bitPattern: subtype)
        return MachOSlice(
            index: index,
            architecture: architecture,
            cpuType: Int32(bitPattern: 0x0100_000C),
            cpuSubtype: subtype,
            cpuSubtypeBase: raw & 0x00FF_FFFF,
            cpuSubtypeCapabilities: raw & 0xFF00_0000,
            fileType: .executable,
            fileTypeValue: 2,
            endianness: .little,
            is64Bit: true,
            platform: platform,
            platformValue: platform == .iPhoneOS ? 2 : 7,
            minimumOSVersion: "15.0",
            sdkVersion: "26.0",
            encrypted: false,
            encryptionCryptID: 0,
            encryptionOffset: 0,
            encryptionSize: 0,
            fileOffset: 0,
            fileSize: 4_096,
            installName: nil,
            linkedLibraries: []
        )
    }
}
