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
        let builder = PatchDylibBuilder(commandRunner: runner)
        let firstRecord = try builder.build(makeProject(), outputDirectory: output)

        XCTAssertEqual(try Data(contentsOf: dylibURL), Data("first dylib".utf8))
        XCTAssertEqual(firstRecord.architecture, .arm64)
        XCTAssertEqual(firstRecord.minimumIOSVersion, "15.2")
        XCTAssertEqual(firstRecord.installName, "@rpath/FixturePatch.dylib")
        XCTAssertEqual(firstRecord.toolchain.sdkVersion, "26.0")
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

        runner.compilerOutput = Data("second dylib".utf8)
        let secondRecord = try builder.build(makeProject(), outputDirectory: output)
        XCTAssertEqual(try Data(contentsOf: dylibURL), Data("second dylib".utf8))
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
        runner.compilerOutput = Data("partial dylib".utf8)

        XCTAssertThrowsError(
            try PatchDylibBuilder(commandRunner: runner).build(
                makeProject(),
                outputDirectory: workspace
            )
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

    func testRejectsArm64eUntilArchitectureCapabilityResolutionExists() throws {
        let workspace = temporaryWorkspace(named: "Architecture Guard")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = FakeBuildCommandRunner()
        let project = makeProject(
            architectureMode: .automatic,
            targetArchitecture: .arm64e
        )

        XCTAssertThrowsError(
            try PatchDylibBuilder(commandRunner: runner).build(
                project,
                outputDirectory: workspace
            )
        ) { error in
            XCTAssertEqual(
                error as? PatchDylibBuilderError,
                .ordinaryArm64Required(mode: .automatic, target: .arm64e)
            )
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testExplicitArm64eModeIsNotSilentlyRelabeledAsArm64() throws {
        let workspace = temporaryWorkspace(named: "Explicit Architecture Guard")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = FakeBuildCommandRunner()

        XCTAssertThrowsError(
            try PatchDylibBuilder(commandRunner: runner).build(
                makeProject(architectureMode: .arm64e),
                outputDirectory: workspace
            )
        ) { error in
            XCTAssertEqual(
                error as? PatchDylibBuilderError,
                .ordinaryArm64Required(mode: .arm64e, target: .arm64)
            )
        }
        XCTAssertTrue(runner.invocations.isEmpty)
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
            try PatchDylibBuilder(commandRunner: runner).build(
                makeProject(),
                outputDirectory: workspace
            )
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
            try PatchDylibBuilder(commandRunner: runner).build(
                makeProject(),
                outputDirectory: workspace
            )
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

    private func temporaryWorkspace(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func makeProject(
        architectureMode: PatchArchitectureMode = .automatic,
        targetArchitecture: MachOArchitecture = .arm64
    ) -> PatchProject {
        PatchProject(
            projectName: "Builder Fixture",
            target: PatchTargetIdentity(
                bundleIdentifier: "com.example.fixture",
                executableName: "Fixture",
                executableSHA256: String(repeating: "a", count: 64),
                selectedSlice: PatchSelectedSlice(
                    architecture: targetArchitecture,
                    cpuSubtype: targetArchitecture == .arm64 ? 0 : 2
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

private final class FakeBuildCommandRunner: BuildCommandRunning, @unchecked Sendable {
    static let clangPath =
        "/Applications/Fake Xcode.app/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    static let sdkPath =
        "/Applications/Fake Xcode.app/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"

    private(set) var invocations: [BuildCommandInvocation] = []
    var compilerStatus: Int32 = 0
    var compilerStandardError = ""
    var compilerOutput = Data("first dylib".utf8)
    var sdkDiscoveryStatus: Int32 = 0

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
        default:
            guard invocation.executablePath == Self.clangPath,
                invocation.arguments.contains("-dynamiclib")
            else {
                return result(invocation, error: "unexpected command\n", status: 127)
            }
            if let outputFlag = invocation.arguments.firstIndex(of: "-o"),
                invocation.arguments.indices.contains(outputFlag + 1)
            {
                try compilerOutput.write(
                    to: URL(filePath: invocation.arguments[outputFlag + 1])
                )
            }
            return result(
                invocation,
                error: compilerStandardError,
                status: compilerStatus
            )
        }
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
