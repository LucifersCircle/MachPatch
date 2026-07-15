import Foundation
import MachPatchCore
import XCTest

@testable import MachPatchBuilder

final class PatchDylibBuilderTests: XCTestCase {
    func testBuildsArm64DylibFromPathsWithSpacesAndSupportsCleanRebuild() throws {
        let workspace = temporaryWorkspace(named: "Builder With Spaces")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let output = workspace.appending(path: "Build Output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let dylibURL = output.appending(path: "FixturePatch.dylib")
        let recordURL = output.appending(path: MachPatchBuilder.buildRecordFileName)
        try Data("stale dylib".utf8).write(to: dylibURL)
        try Data("stale record".utf8).write(to: recordURL)

        let runner = FakeBuildCommandRunner()
        let prober = FakeArchitectureProber()
        let builder = PatchDylibBuilder(commandRunner: runner, architectureProber: prober)
        let progress = BuildProgressRecorder()
        let firstRecord = try builder.build(
            makeProject(),
            outputDirectory: output,
            progress: { progress.append($0) }
        )

        let firstDylib = try Data(contentsOf: dylibURL)
        XCTAssertEqual(firstDylib.last, 1)
        XCTAssertEqual(firstRecord.formatVersion, 2)
        XCTAssertEqual(firstRecord.architecture, .arm64)
        XCTAssertEqual(firstRecord.minimumIOSVersion, "15.2")
        XCTAssertEqual(firstRecord.installName, "@rpath/FixturePatch.dylib")
        XCTAssertEqual(firstRecord.toolchain.sdkVersion, "26.0")
        XCTAssertEqual(firstRecord.slices.count, 1)
        XCTAssertEqual(firstRecord.slices[0].cpuSubtype, 0)
        XCTAssertEqual(firstRecord.capabilityProbes.map(\.requestedArchitecture), [.arm64])
        XCTAssertEqual(
            progress.values.map(\.phase),
            [
                .generatingSource, .discoveringToolchain, .probingArchitecture, .compiling,
                .recordingOutput, .completed,
            ]
        )
        XCTAssertEqual(progress.values.last?.fractionCompleted, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(PatchBuildRecord.self, from: Data(contentsOf: recordURL)),
            firstRecord
        )

        let compile = try XCTUnwrap(
            runner.invocations.last(where: { $0.arguments.contains("-dynamiclib") })
        )
        XCTAssertEqual(compile.executablePath, FakeBuildCommandRunner.clangPath)
        XCTAssertTrue(compile.arguments.contains("-arch"))
        XCTAssertTrue(compile.arguments.contains("arm64"))
        XCTAssertTrue(compile.arguments.contains("-isysroot"))
        XCTAssertTrue(compile.arguments.contains(FakeBuildCommandRunner.sdkPath))
        XCTAssertTrue(compile.arguments.contains("-miphoneos-version-min=15.2"))
        XCTAssertTrue(compile.arguments.contains("-fobjc-arc"))
        XCTAssertTrue(
            compile.arguments.contains("-Wl,-install_name,@rpath/FixturePatch.dylib")
        )
        XCTAssertTrue(compile.arguments.contains(firstRecord.sourcePath))
        XCTAssertTrue(compile.arguments.contains(firstRecord.outputPath))
        XCTAssertFalse(
            runner.invocations.contains {
                ["/bin/sh", "/bin/zsh", "/usr/bin/env"].contains($0.executablePath)
            }
        )

        runner.compilerMarker = 2
        let secondRecord = try builder.build(makeProject(), outputDirectory: output)
        XCTAssertEqual(try Data(contentsOf: dylibURL).last, 2)
        XCTAssertNotEqual(try Data(contentsOf: dylibURL), firstDylib)
        XCTAssertEqual(secondRecord.outputPath, firstRecord.outputPath)
    }

    func testCompilerFailureReturnsDiagnosticsAndRemovesStaleOrPartialProducts() throws {
        let workspace = temporaryWorkspace(named: "Compiler Failure")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let dylibURL = workspace.appending(path: "FixturePatch.dylib")
        let recordURL = workspace.appending(path: MachPatchBuilder.buildRecordFileName)
        try Data("stale dylib".utf8).write(to: dylibURL)
        try Data("stale record".utf8).write(to: recordURL)

        let runner = FakeBuildCommandRunner()
        runner.compilerStatus = 1
        runner.compilerStandardError = "Fixture.m:12:3: error: synthetic compile failure\n"

        XCTAssertThrowsError(
            try makeBuilder(runner).build(makeProject(), outputDirectory: workspace)
        ) { error in
            guard case .compilerFailed(let execution) = error as? PatchDylibBuilderError else {
                return XCTFail("Expected compilerFailed, received \(error)")
            }
            XCTAssertEqual(execution.terminationStatus, 1)
            XCTAssertTrue(execution.standardError.contains("synthetic compile failure"))
            XCTAssertTrue(error.localizedDescription.contains("synthetic compile failure"))
            XCTAssertTrue(error.localizedDescription.contains("-dynamiclib"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dylibURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func testBuildsModernArm64eOnlyAfterCapabilityProbe() throws {
        let workspace = temporaryWorkspace(named: "arm64e Build")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = FakeBuildCommandRunner()
        let prober = FakeArchitectureProber()
        let project = makeProject(
            architectureMode: .automatic,
            targetArchitecture: .arm64e,
            targetCPUSubtype: Int32(bitPattern: 0x8000_0002)
        )

        let record = try PatchDylibBuilder(
            commandRunner: runner,
            architectureProber: prober
        ).build(project, outputDirectory: workspace)

        XCTAssertEqual(prober.requestedArchitectures, [.arm64e])
        XCTAssertEqual(record.architecture, .arm64e)
        XCTAssertEqual(record.slices.map(\.architecture), [.arm64e])
        XCTAssertEqual(record.slices[0].cpuSubtype, Int32(bitPattern: 0x8000_0002))
        let compile = try XCTUnwrap(
            runner.invocations.last(where: { $0.arguments.contains("-dynamiclib") })
        )
        XCTAssertTrue(compile.arguments.contains("arm64e"))
    }

    func testExplicitArchitectureCannotRelabelTarget() throws {
        let workspace = temporaryWorkspace(named: "Explicit Architecture Guard")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = FakeBuildCommandRunner()

        XCTAssertThrowsError(
            try makeBuilder(runner).build(
                makeProject(architectureMode: .arm64e),
                outputDirectory: workspace
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchitectureResolutionError,
                .modeIncompatibleWithTarget(.arm64e, .arm64)
            )
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testUniversalBuildMergesOnlyValidatedThinSlices() throws {
        let workspace = temporaryWorkspace(named: "Universal Build")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = FakeBuildCommandRunner()
        let prober = FakeArchitectureProber()

        let record = try PatchDylibBuilder(
            commandRunner: runner,
            architectureProber: prober
        ).build(
            makeProject(),
            outputDirectory: workspace,
            architectureMode: .universal
        )

        XCTAssertEqual(prober.requestedArchitectures, [.arm64, .arm64e])
        XCTAssertEqual(record.architecture, .universal)
        XCTAssertEqual(record.slices.map(\.architecture), [.arm64, .arm64e])
        XCTAssertEqual(record.symbolChecks.count, 2)
        XCTAssertNotNil(record.merge)
        XCTAssertTrue(record.slices[0].outputPath.hasSuffix("FixturePatch-arm64.dylib"))
        XCTAssertTrue(record.slices[1].outputPath.hasSuffix("FixturePatch-arm64e.dylib"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.outputPath))
        XCTAssertEqual(
            runner.invocations.filter { $0.arguments.contains("-dynamiclib") }.count,
            2
        )
        XCTAssertEqual(
            runner.invocations.filter { $0.executablePath == FakeBuildCommandRunner.lipoPath }
                .count,
            1
        )
    }

    func testArm64eProbeSubtypeMustExactlyMatchTargetBeforeCompilation() throws {
        let workspace = temporaryWorkspace(named: "Subtype Mismatch")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = FakeBuildCommandRunner()
        let prober = FakeArchitectureProber()
        let project = makeProject(
            targetArchitecture: .arm64e,
            targetCPUSubtype: Int32(bitPattern: 0x8300_0002)
        )

        XCTAssertThrowsError(
            try PatchDylibBuilder(
                commandRunner: runner,
                architectureProber: prober
            ).build(project, outputDirectory: workspace)
        ) { error in
            guard case .outputValidationFailed(let message) = error as? PatchDylibBuilderError
            else {
                return XCTFail("Expected outputValidationFailed, received \(error)")
            }
            XCTAssertTrue(message.contains("does not exactly match target subtype"))
        }
        XCTAssertFalse(runner.invocations.contains { $0.arguments.contains("-dynamiclib") })
    }

    func testUniversalBuildRejectsMismatchedExportedSymbolsBeforeLipo() throws {
        let workspace = temporaryWorkspace(named: "Symbol Mismatch")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = FakeBuildCommandRunner()
        runner.arm64eSymbols = "_DifferentExport\n"

        XCTAssertThrowsError(
            try makeBuilder(runner).build(
                makeProject(),
                outputDirectory: workspace,
                architectureMode: .universal
            )
        ) { error in
            guard case .outputValidationFailed(let message) = error as? PatchDylibBuilderError
            else {
                return XCTFail("Expected outputValidationFailed, received \(error)")
            }
            XCTAssertTrue(message.contains("export different symbols"))
        }
        XCTAssertFalse(
            runner.invocations.contains { $0.executablePath == FakeBuildCommandRunner.lipoPath }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.appending(path: "FixturePatch-arm64.dylib").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.appending(path: "FixturePatch-arm64e.dylib").path
            )
        )
    }

    func testUnsupportedToolchainProbeBlocksCompilationWithDiagnostics() throws {
        let workspace = temporaryWorkspace(named: "Unsupported Probe")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = FakeBuildCommandRunner()
        let prober = FakeArchitectureProber()
        prober.unsupportedArchitectures = [.arm64e]
        let project = makeProject(
            targetArchitecture: .arm64e,
            targetCPUSubtype: Int32(bitPattern: 0x8000_0002)
        )

        XCTAssertThrowsError(
            try PatchDylibBuilder(
                commandRunner: runner,
                architectureProber: prober
            ).build(project, outputDirectory: workspace)
        ) { error in
            guard
                case .toolchainArchitectureUnsupported(let probe) =
                    error as? PatchDylibBuilderError
            else {
                return XCTFail("Expected toolchainArchitectureUnsupported, received \(error)")
            }
            XCTAssertEqual(probe.requestedArchitecture, .arm64e)
            XCTAssertTrue(error.localizedDescription.contains("synthetic unsupported architecture"))
        }
        XCTAssertFalse(runner.invocations.contains { $0.arguments.contains("-dynamiclib") })
    }

    func testRejectsSymlinkDylibDestinationWithoutFollowingIt() throws {
        let workspace = temporaryWorkspace(named: "Symlink Guard")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let destination = workspace.appending(path: "FixturePatch.dylib")
        let outside = workspace.appending(path: "outside")
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: outside
        )
        let runner = FakeBuildCommandRunner()

        XCTAssertThrowsError(
            try makeBuilder(runner).build(makeProject(), outputDirectory: workspace)
        ) { error in
            XCTAssertEqual(
                error as? PatchDylibBuilderError,
                .unsafeOutputPath(destination.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testToolchainFailureIncludesExactCommandAndDiagnostics() throws {
        let workspace = temporaryWorkspace(named: "Toolchain Failure")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = FakeBuildCommandRunner()
        runner.sdkDiscoveryStatus = 72

        XCTAssertThrowsError(
            try makeBuilder(runner).build(makeProject(), outputDirectory: workspace)
        ) { error in
            guard case .commandFailed(let execution) = error as? AppleToolchainDiscoveryError else {
                return XCTFail("Expected commandFailed, received \(error)")
            }
            XCTAssertEqual(execution.terminationStatus, 72)
            XCTAssertEqual(
                execution.invocation.arguments,
                ["--sdk", "iphoneos", "--show-sdk-path"]
            )
            XCTAssertTrue(error.localizedDescription.contains("iPhoneOS SDK is unavailable"))
        }
    }

    private func makeBuilder(_ runner: FakeBuildCommandRunner) -> PatchDylibBuilder {
        PatchDylibBuilder(
            commandRunner: runner,
            architectureProber: FakeArchitectureProber()
        )
    }

    private func temporaryWorkspace(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func makeProject(
        architectureMode: PatchArchitectureMode = .automatic,
        targetArchitecture: MachOArchitecture = .arm64,
        targetCPUSubtype: Int32? = nil
    ) -> PatchProject {
        let subtype = targetCPUSubtype ?? (targetArchitecture == .arm64 ? 0 : 2)
        return PatchProject(
            projectName: "Builder Fixture",
            target: PatchTargetIdentity(
                bundleIdentifier: "com.example.fixture",
                executableName: "Fixture",
                executableSHA256: String(repeating: "a", count: 64),
                selectedSlice: PatchSelectedSlice(
                    architecture: targetArchitecture,
                    cpuSubtype: subtype
                ),
                minimumIOSVersion: "15.0"
            ),
            build: PatchBuildConfiguration(
                architectureMode: architectureMode,
                minimumIOSVersion: "15.2",
                outputName: "FixturePatch",
                enableARC: true
            ),
            patches: [
                MethodPatch(
                    id: "4F154FAA-1E35-44AA-B014-30EAE65C3F47",
                    enabled: true,
                    className: "FixtureManager",
                    selector: "featureEnabled",
                    methodKind: .instance,
                    expectedTypeEncoding: "B@:",
                    action: .returnBoolean(true)
                )
            ]
        )
    }
}

private final class BuildProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PatchBuildProgress] = []

    var values: [PatchBuildProgress] {
        lock.withLock { storage }
    }

    func append(_ progress: PatchBuildProgress) {
        lock.withLock { storage.append(progress) }
    }
}

private final class FakeArchitectureProber: ToolchainArchitectureProbing, @unchecked Sendable {
    private(set) var requestedArchitectures: [BuildSliceArchitecture] = []
    var unsupportedArchitectures: Set<BuildSliceArchitecture> = []
    var arm64eSubtype = Int32(bitPattern: 0x8000_0002)

    func probe(
        _ architecture: BuildSliceArchitecture,
        toolchain: AppleToolchain,
        minimumIOSVersion: String
    ) throws -> ToolchainArchitectureProbe {
        requestedArchitectures.append(architecture)
        let invocation = BuildCommandInvocation(
            executablePath: toolchain.clangPath,
            arguments: ["synthetic-probe", architecture.rawValue]
        )
        let unsupported = unsupportedArchitectures.contains(architecture)
        let subtype: Int32 = architecture == .arm64 ? 0 : arm64eSubtype
        let raw = UInt32(bitPattern: subtype)
        return ToolchainArchitectureProbe(
            requestedArchitecture: architecture,
            supported: !unsupported,
            execution: BuildCommandExecution(
                invocation: invocation,
                standardOutput: "",
                standardError: unsupported ? "synthetic unsupported architecture" : "",
                terminationStatus: unsupported ? 1 : 0,
                durationMilliseconds: 2
            ),
            outputArchitecture: unsupported ? nil : architecture.machOArchitecture,
            outputCPUSubtype: unsupported ? nil : subtype,
            outputCPUSubtypeBase: unsupported ? nil : raw & 0x00FF_FFFF,
            outputCPUSubtypeCapabilities: unsupported ? nil : raw & 0xFF00_0000,
            outputPlatform: unsupported ? nil : .iPhoneOS,
            outputMinimumOSVersion: unsupported ? nil : minimumIOSVersion,
            failureReason: unsupported ? "synthetic unsupported architecture" : nil
        )
    }
}

private final class FakeBuildCommandRunner: BuildCommandRunning, @unchecked Sendable {
    static let clangPath =
        "/Applications/Fake Xcode.app/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    static let lipoPath =
        "/Applications/Fake Xcode.app/Toolchains/XcodeDefault.xctoolchain/usr/bin/lipo"
    static let nmPath =
        "/Applications/Fake Xcode.app/Toolchains/XcodeDefault.xctoolchain/usr/bin/nm"
    static let sdkPath =
        "/Applications/Fake Xcode.app/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"

    private(set) var invocations: [BuildCommandInvocation] = []
    var compilerStatus: Int32 = 0
    var compilerStandardError = ""
    var compilerMarker: UInt8 = 1
    var sdkDiscoveryStatus: Int32 = 0
    var arm64Symbols = "_MachPatchExport\n"
    var arm64eSymbols = "_MachPatchExport\n"

    func run(_ invocation: BuildCommandInvocation) throws -> BuildCommandExecution {
        invocations.append(invocation)
        switch (invocation.executablePath, invocation.arguments) {
        case ("/usr/bin/xcode-select", ["-p"]):
            return result(invocation, output: "/Applications/Fake Xcode.app/Contents/Developer\n")
        case ("/usr/bin/xcrun", ["--sdk", "iphoneos", "--find", "clang"]):
            return result(invocation, output: "\(Self.clangPath)\n")
        case ("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"]):
            return result(
                invocation,
                error: sdkDiscoveryStatus == 0 ? "" : "iPhoneOS SDK is unavailable\n",
                status: sdkDiscoveryStatus,
                output: sdkDiscoveryStatus == 0 ? "\(Self.sdkPath)\n" : ""
            )
        case ("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"]):
            return result(invocation, output: "26.0\n")
        case ("/usr/bin/xcrun", ["xcodebuild", "-version"]):
            return result(invocation, output: "Xcode 26.0\nBuild version 17A000\n")
        case (Self.clangPath, ["--version"]):
            return result(invocation, output: "Apple clang version 17.0.0\n")
        case ("/usr/bin/xcrun", ["--find", "lipo"]):
            return result(invocation, output: "\(Self.lipoPath)\n")
        case ("/usr/bin/xcrun", ["--find", "nm"]):
            return result(invocation, output: "\(Self.nmPath)\n")
        default:
            if invocation.executablePath == Self.nmPath {
                let output =
                    invocation.arguments.last?.contains("-arm64e.dylib") == true
                    ? arm64eSymbols : arm64Symbols
                return result(invocation, output: output)
            }
            if invocation.executablePath == Self.lipoPath {
                try writeUniversalOutput(for: invocation)
                return result(invocation)
            }
            guard invocation.executablePath == Self.clangPath,
                invocation.arguments.contains("-dynamiclib")
            else {
                return result(invocation, error: "unexpected command\n", status: 127)
            }
            try writeThinOutput(for: invocation)
            return result(
                invocation,
                error: compilerStandardError,
                status: compilerStatus
            )
        }
    }

    private func writeThinOutput(for invocation: BuildCommandInvocation) throws {
        guard let outputPath = value(after: "-o", in: invocation.arguments),
            let architectureName = value(after: "-arch", in: invocation.arguments),
            let deployment = invocation.arguments.first(where: {
                $0.hasPrefix("-miphoneos-version-min=")
            })?.split(separator: "=").last.map(String.init),
            let installName = invocation.arguments.first(where: {
                $0.hasPrefix("-Wl,-install_name,")
            }).map({ String($0.dropFirst("-Wl,-install_name,".count)) })
        else {
            return
        }
        let subtype: UInt32 = architectureName == "arm64e" ? 0x8000_0002 : 0
        var data = MachOTestData.thinDylib(
            cpuSubtype: subtype,
            minimumVersion: deployment,
            installName: installName
        )
        data.append(compilerMarker)
        try data.write(to: URL(filePath: outputPath))
    }

    private func writeUniversalOutput(for invocation: BuildCommandInvocation) throws {
        guard invocation.arguments.count == 5,
            invocation.arguments[0] == "-create",
            invocation.arguments[3] == "-output"
        else { return }
        let arm64 = try Data(contentsOf: URL(filePath: invocation.arguments[1]))
        let arm64e = try Data(contentsOf: URL(filePath: invocation.arguments[2]))
        try MachOTestData.fat32(slices: [arm64, arm64e]).write(
            to: URL(filePath: invocation.arguments[4])
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private func result(
        _ invocation: BuildCommandInvocation,
        error: String = "",
        status: Int32 = 0,
        output: String = ""
    ) -> BuildCommandExecution {
        BuildCommandExecution(
            invocation: invocation,
            standardOutput: output,
            standardError: error,
            terminationStatus: status,
            durationMilliseconds: 7
        )
    }
}

private enum MachOTestData {
    static func thinDylib(
        cpuSubtype: UInt32,
        minimumVersion: String,
        installName: String
    ) -> Data {
        var name = Data(installName.utf8)
        name.append(0)
        let identifierSize = aligned(24 + name.count, to: 8)
        let commandBytes = 24 + identifierSize
        var data = Data()
        data.appendUInt32(0xFEED_FACF, endianness: .little)
        data.appendUInt32(0x0100_000C, endianness: .little)
        data.appendUInt32(cpuSubtype, endianness: .little)
        data.appendUInt32(6, endianness: .little)
        data.appendUInt32(2, endianness: .little)
        data.appendUInt32(UInt32(commandBytes), endianness: .little)
        data.appendUInt32(0, endianness: .little)
        data.appendUInt32(0, endianness: .little)

        data.appendUInt32(0x32, endianness: .little)
        data.appendUInt32(24, endianness: .little)
        data.appendUInt32(2, endianness: .little)
        data.appendUInt32(encodedVersion(minimumVersion), endianness: .little)
        data.appendUInt32(encodedVersion("26.0"), endianness: .little)
        data.appendUInt32(0, endianness: .little)

        data.appendUInt32(0x0D, endianness: .little)
        data.appendUInt32(UInt32(identifierSize), endianness: .little)
        data.appendUInt32(24, endianness: .little)
        data.appendUInt32(0, endianness: .little)
        data.appendUInt32(0, endianness: .little)
        data.appendUInt32(0, endianness: .little)
        data.append(name)
        data.append(Data(repeating: 0, count: identifierSize - 24 - name.count))
        return data
    }

    static func fat32(slices: [Data]) -> Data {
        precondition(slices.count == 2)
        let firstOffset = 4_096
        let secondOffset = aligned(firstOffset + slices[0].count, to: 4_096)
        let subtypes: [UInt32] = [0, 0x8000_0002]
        let offsets = [firstOffset, secondOffset]
        var data = Data()
        data.appendUInt32(0xCAFE_BABE, endianness: .big)
        data.appendUInt32(2, endianness: .big)
        for index in slices.indices {
            data.appendUInt32(0x0100_000C, endianness: .big)
            data.appendUInt32(subtypes[index], endianness: .big)
            data.appendUInt32(UInt32(offsets[index]), endianness: .big)
            data.appendUInt32(UInt32(slices[index].count), endianness: .big)
            data.appendUInt32(12, endianness: .big)
        }
        data.append(Data(repeating: 0, count: firstOffset - data.count))
        data.append(slices[0])
        data.append(Data(repeating: 0, count: secondOffset - data.count))
        data.append(slices[1])
        return data
    }

    private static func encodedVersion(_ value: String) -> UInt32 {
        let components = value.split(separator: ".").compactMap { UInt32($0) }
        return ((components.first ?? 0) << 16)
            | ((components.indices.contains(1) ? components[1] : 0) << 8)
            | (components.indices.contains(2) ? components[2] : 0)
    }

    private static func aligned(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}

private enum TestEndianness {
    case little
    case big
}

extension Data {
    fileprivate mutating func appendUInt32(_ value: UInt32, endianness: TestEndianness) {
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
}
