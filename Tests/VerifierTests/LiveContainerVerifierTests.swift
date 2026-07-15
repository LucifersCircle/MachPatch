import Foundation
import MachPatchAnalyzer
import MachPatchCore
import XCTest

@testable import MachPatchVerifier

final class LiveContainerVerifierTests: XCTestCase {
    func testReadyReportConfirmsDeviceDylibAndMatchingTarget() throws {
        let dylib = VerifierMachOFixture.thin64(
            fileType: 6,
            installName: "@rpath/Fixture.dylib",
            libraries: [
                "/usr/lib/libSystem.B.dylib",
                "/usr/lib/libobjc.A.dylib",
                "/System/Library/Frameworks/Foundation.framework/Foundation",
            ]
        )
        let target = VerifierMachOFixture.thin64(fileType: 2)
        let report = try verify(
            dylib,
            target: target,
            nmOutput: """
                             (undefined) external _objc_getClass (from libobjc)
                             (undefined) external _NSLog (from Foundation)
                """
        )

        XCTAssertTrue(report.isReadyForLiveContainerTesting)
        XCTAssertTrue(report.blockingFailures.isEmpty)
        XCTAssertEqual(report.slices.map(\.architecture), [.arm64])
        XCTAssertEqual(report.lipoArchitectures, ["arm64"])
        XCTAssertEqual(report.dependencies.count, 3)
        XCTAssertTrue(report.dependencies.allSatisfy { $0.classification == .appleSystem })
        XCTAssertEqual(
            report.unresolvedSymbols.map(\.classification),
            [.expectedAppleRuntime, .expectedAppleFramework]
        )
        XCTAssertEqual(
            check(.targetCompatibility, in: report)?.status,
            .passed
        )
    }

    func testDetectsSimulatorDylibDespiteArm64CPUType() throws {
        let report = try verify(
            VerifierMachOFixture.thin64(
                fileType: 6,
                platform: 7,
                installName: "@rpath/Fixture.dylib"
            )
        )

        XCTAssertFalse(report.isReadyForLiveContainerTesting)
        XCTAssertEqual(check(.platform, in: report)?.status, .failed)
        XCTAssertTrue(check(.platform, in: report)?.message.contains("iPhoneSimulator") == true)
    }

    func testDetectsVarJBStringAndCydiaSubstrateDependency() throws {
        var dylib = VerifierMachOFixture.thin64(
            fileType: 6,
            installName: "@rpath/Fixture.dylib",
            libraries: [
                "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
            ]
        )
        dylib.append(0)
        dylib.append(Data("/var/jb/usr/lib/Injected.dylib".utf8))
        dylib.append(0)

        let report = try verify(dylib)

        XCTAssertFalse(report.isReadyForLiveContainerTesting)
        XCTAssertEqual(report.dependencies.first?.classification, .forbiddenJailbreak)
        XCTAssertEqual(check(.dependency, in: report)?.status, .failed)
        XCTAssertEqual(check(.forbiddenFilesystemPath, in: report)?.status, .failed)
        XCTAssertTrue(report.forbiddenPaths.contains { $0.marker == "/var/jb" })
    }

    func testDetectsAbsoluteDevelopmentMachineInstallName() throws {
        let report = try verify(
            VerifierMachOFixture.thin64(
                fileType: 6,
                installName: "/Users/developer/Build/Fixture.dylib"
            )
        )

        XCTAssertEqual(check(.installName, in: report)?.status, .failed)
        XCTAssertTrue(
            check(.installName, in: report)?.message.contains("development-machine") == true
        )
    }

    func testDetectsTargetArchitectureAndSubtypeMismatch() throws {
        let dylib = VerifierMachOFixture.thin64(
            fileType: 6,
            installName: "@rpath/Fixture.dylib"
        )
        let arm64eTarget = VerifierMachOFixture.thin64(
            cpuSubtype: 0x8000_0002,
            fileType: 2
        )

        let report = try verify(dylib, target: arm64eTarget)

        XCTAssertEqual(check(.targetCompatibility, in: report)?.status, .failed)
        XCTAssertTrue(
            check(.targetCompatibility, in: report)?.message.contains("no architecture") == true
        )
    }

    func testDetectsUnexpectedUnresolvedSymbol() throws {
        let report = try verify(
            VerifierMachOFixture.thin64(
                fileType: 6,
                installName: "@rpath/Fixture.dylib"
            ),
            nmOutput: "                 (undefined) external _ThirdPartyHook (from ThirdParty)"
        )

        XCTAssertEqual(report.unresolvedSymbols.first?.name, "_ThirdPartyHook")
        XCTAssertEqual(report.unresolvedSymbols.first?.provider, "ThirdParty")
        XCTAssertEqual(
            report.unresolvedSymbols.first?.classification,
            .unexpectedExternal
        )
        XCTAssertEqual(check(.unresolvedSymbols, in: report)?.status, .failed)
    }

    func testDetectsLegacyArm64eOutput() throws {
        let report = try verify(
            VerifierMachOFixture.thin64(
                cpuSubtype: 2,
                fileType: 6,
                installName: "@rpath/Fixture.dylib"
            ),
            lipoOutput: "arm64e"
        )

        XCTAssertEqual(check(.architecture, in: report)?.status, .failed)
        XCTAssertTrue(check(.architecture, in: report)?.message.contains("legacy arm64e") == true)
    }

    func testDetectsDeploymentTargetNewerThanMatchingTarget() throws {
        let dylib = VerifierMachOFixture.thin64(
            fileType: 6,
            minimumVersion: VerifierMachOFixture.packedVersion(16, 0),
            installName: "@rpath/Fixture.dylib"
        )
        let target = VerifierMachOFixture.thin64(fileType: 2)

        let report = try verify(dylib, target: target)

        let deploymentChecks = report.checks.filter { $0.code == .deploymentTarget }
        XCTAssertTrue(deploymentChecks.contains { $0.status == .failed })
        XCTAssertTrue(
            deploymentChecks.contains {
                $0.message.contains("requires a newer iOS version")
            }
        )
    }

    func testDetectsLipoAndNativeArchitectureDisagreement() throws {
        let report = try verify(
            VerifierMachOFixture.thin64(
                fileType: 6,
                installName: "@rpath/Fixture.dylib"
            ),
            lipoOutput: "arm64e"
        )

        XCTAssertEqual(check(.lipoAgreement, in: report)?.status, .failed)
    }

    func testHumanAndJSONReportsExposeBlockingResult() throws {
        let report = try verify(
            VerifierMachOFixture.thin64(
                fileType: 6,
                platform: 7,
                installName: "@rpath/Fixture.dylib"
            )
        )

        let human = HumanVerificationReportFormatter.render(report)
        XCTAssertTrue(human.contains("LiveContainer compatibility"))
        XCTAssertTrue(human.contains("FAIL Slice 0 targets iPhoneSimulator"))
        XCTAssertTrue(human.contains("Blocked by"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        XCTAssertTrue(json.contains("\"formatVersion\":1"))
        XCTAssertTrue(json.contains("\"result\":\"blocked\""))
        XCTAssertTrue(json.contains("\"status\":\"failed\""))
        XCTAssertTrue(json.contains("\"platform\":\"iPhoneSimulator\""))
    }

    func testIncludedAdjacentRPathDependencyIsAccepted() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let dylibURL = directory.appending(path: "Fixture.dylib")
        let companionURL = directory.appending(path: "Companion.dylib")
        try Data([0]).write(to: companionURL)
        try VerifierMachOFixture.thin64(
            fileType: 6,
            installName: "@rpath/Fixture.dylib",
            libraries: ["@rpath/Companion.dylib"]
        ).write(to: dylibURL)

        let report = try makeVerifier().verify(dylibURL: dylibURL)

        XCTAssertEqual(report.dependencies.first?.classification, .includedAdjacent)
        XCTAssertEqual(report.dependencies.first?.resolvedPath, companionURL.path)
        XCTAssertEqual(check(.dependency, in: report)?.status, .passed)
    }

    func testUnknownAbsoluteUSRLIBDependencyIsNotAssumedToBeApple() throws {
        let report = try verify(
            VerifierMachOFixture.thin64(
                fileType: 6,
                installName: "@rpath/Fixture.dylib",
                libraries: ["/usr/lib/libThirdParty.dylib"]
            )
        )

        XCTAssertEqual(report.dependencies.first?.classification, .unsupportedExternal)
        XCTAssertEqual(check(.dependency, in: report)?.status, .failed)
    }

    private func verify(
        _ dylib: Data,
        target: Data? = nil,
        lipoOutput: String = "arm64",
        nmOutput: String = ""
    ) throws -> DylibVerificationReport {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let dylibURL = directory.appending(path: "Fixture.dylib")
        try dylib.write(to: dylibURL)

        let targetInspection: MachOInspection?
        if let target {
            let targetURL = directory.appending(path: "Target")
            try target.write(to: targetURL)
            targetInspection = MachOInspection(
                target: ResolvedTarget(
                    sourceType: .machO,
                    sourcePath: targetURL.path,
                    bundlePath: nil,
                    bundleIdentifier: "com.example.fixture",
                    displayName: "Fixture",
                    minimumOSVersion: "15.0",
                    supportedPlatforms: ["iPhoneOS"],
                    executableName: "Target",
                    executablePath: targetURL.path,
                    sha256: String(repeating: "0", count: 64)
                ),
                slices: try MachOInspector().inspect(at: targetURL)
            )
        } else {
            targetInspection = nil
        }

        return try makeVerifier(lipoOutput: lipoOutput, nmOutput: nmOutput).verify(
            dylibURL: dylibURL,
            targetInspection: targetInspection
        )
    }

    private func makeVerifier(
        lipoOutput: String = "arm64",
        nmOutput: String = ""
    ) -> LiveContainerVerifier {
        LiveContainerVerifier(
            commandRunner: StubVerificationCommandRunner { invocation in
                let output = invocation.executablePath == "/test/lipo" ? lipoOutput : nmOutput
                return VerificationCommandExecution(
                    invocation: invocation,
                    standardOutput: output,
                    standardError: "",
                    terminationStatus: 0,
                    durationMilliseconds: 1
                )
            },
            tools: VerificationTools(lipoPath: "/test/lipo", nmPath: "/test/nm")
        )
    }

    private func check(
        _ code: VerificationCheckCode,
        in report: DylibVerificationReport
    ) -> VerificationCheck? {
        report.checks.first { $0.code == code }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-VerifierTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}

private struct StubVerificationCommandRunner: VerificationCommandRunning {
    let handler: @Sendable (VerificationCommandInvocation) throws -> VerificationCommandExecution

    init(
        handler:
            @escaping @Sendable (VerificationCommandInvocation) throws ->
            VerificationCommandExecution
    ) {
        self.handler = handler
    }

    func run(_ invocation: VerificationCommandInvocation) throws -> VerificationCommandExecution {
        try handler(invocation)
    }
}

private enum VerifierMachOFixture {
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    static func thin64(
        cpuSubtype: UInt32 = 0,
        fileType: UInt32,
        platform: UInt32 = 2,
        minimumVersion: UInt32 = packedVersion(15, 0),
        installName: String? = nil,
        libraries: [String] = []
    ) -> Data {
        var commands = [
            buildVersionCommand(
                platform: platform,
                minimumVersion: minimumVersion,
                sdkVersion: packedVersion(18, 0)
            )
        ]
        if let installName {
            commands.append(dylibCommand(command: 0x0000_000D, path: installName))
        }
        commands.append(contentsOf: libraries.map { dylibCommand(command: 0x0000_000C, path: $0) })

        let commandBytes = commands.reduce(0) { $0 + $1.count }
        var data = Data([0xCF, 0xFA, 0xED, 0xFE])
        data.appendUInt32LE(cpuTypeARM64)
        data.appendUInt32LE(cpuSubtype)
        data.appendUInt32LE(fileType)
        data.appendUInt32LE(UInt32(commands.count))
        data.appendUInt32LE(UInt32(commandBytes))
        data.appendUInt32LE(0)
        data.appendUInt32LE(0)
        commands.forEach { data.append($0) }
        return data
    }

    private static func buildVersionCommand(
        platform: UInt32,
        minimumVersion: UInt32,
        sdkVersion: UInt32
    ) -> Data {
        var data = Data()
        data.appendUInt32LE(0x0000_0032)
        data.appendUInt32LE(24)
        data.appendUInt32LE(platform)
        data.appendUInt32LE(minimumVersion)
        data.appendUInt32LE(sdkVersion)
        data.appendUInt32LE(0)
        return data
    }

    private static func dylibCommand(command: UInt32, path: String) -> Data {
        var pathData = Data(path.utf8)
        pathData.append(0)
        let commandSize = roundUp(24 + pathData.count, alignment: 8)
        var data = Data()
        data.appendUInt32LE(command)
        data.appendUInt32LE(UInt32(commandSize))
        data.appendUInt32LE(24)
        data.appendUInt32LE(0)
        data.appendUInt32LE(packedVersion(1, 0))
        data.appendUInt32LE(packedVersion(1, 0))
        data.append(pathData)
        data.append(Data(count: commandSize - data.count))
        return data
    }

    static func packedVersion(
        _ major: UInt32,
        _ minor: UInt32,
        _ patch: UInt32 = 0
    ) -> UInt32 {
        major << 16 | minor << 8 | patch
    }

    private static func roundUp(_ value: Int, alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
