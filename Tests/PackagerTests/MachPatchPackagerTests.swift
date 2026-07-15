import Foundation
import MachPatchBuilder
import MachPatchCore
import MachPatchPackager
import XCTest

final class MachPatchPackagerTests: XCTestCase {
    func testSourceBundlePreservesProjectSourceAndRebuildInstructions() throws {
        let fixture = try makeFixture(architecture: .arm64)
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }

        let bundle = try PatchSourceBundleBuilder().build(
            project: fixture.project,
            buildRecord: fixture.record,
            sourceURL: fixture.sourceURL
        )

        XCTAssertEqual(bundle.directoryName, "FixturePatchSource")
        XCTAssertEqual(
            bundle.files.map(\.relativePath),
            ["patch.json", "MachPatchGenerated.m", "build.sh", "README.md"]
        )
        let files = Dictionary(uniqueKeysWithValues: bundle.files.map { ($0.relativePath, $0) })
        XCTAssertEqual(
            try PatchProjectCodec.decode(try XCTUnwrap(files["patch.json"]?.contents)),
            fixture.project
        )
        XCTAssertEqual(
            String(data: try XCTUnwrap(files["MachPatchGenerated.m"]?.contents), encoding: .utf8),
            "// generated fixture\n"
        )
        let buildScript = try XCTUnwrap(
            String(data: try XCTUnwrap(files["build.sh"]?.contents), encoding: .utf8)
        )
        XCTAssertTrue(buildScript.contains("xcrun --sdk iphoneos --show-sdk-path"))
        XCTAssertTrue(buildScript.contains("-arch arm64"))
        XCTAssertTrue(buildScript.contains("-miphoneos-version-min=15.0"))
        XCTAssertTrue(buildScript.contains("@rpath/FixturePatch.dylib"))
        XCTAssertTrue(try XCTUnwrap(files["build.sh"]?.isExecutable))
        let readme = try XCTUnwrap(
            String(data: try XCTUnwrap(files["README.md"]?.contents), encoding: .utf8)
        )
        XCTAssertTrue(readme.contains(fixture.project.target.executableSHA256))
        XCTAssertTrue(readme.contains("com.example.fixture"))

        let repeated = try PatchSourceBundleBuilder().build(
            project: fixture.project,
            buildRecord: fixture.record,
            sourceURL: fixture.sourceURL
        )
        XCTAssertEqual(repeated, bundle)
    }

    func testUniversalSourceBundleBuildsThinSlicesBeforeLipo() throws {
        let fixture = try makeFixture(architecture: .universal)
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }

        let bundle = try PatchSourceBundleBuilder().build(
            project: fixture.project,
            buildRecord: fixture.record,
            sourceURL: fixture.sourceURL
        )
        let scriptData = try XCTUnwrap(
            bundle.files.first(where: { $0.relativePath == "build.sh" })?.contents
        )
        let script = try XCTUnwrap(String(data: scriptData, encoding: .utf8))

        XCTAssertTrue(script.contains("-arch arm64 "))
        XCTAssertTrue(script.contains("-arch arm64e "))
        XCTAssertTrue(script.contains("\"$LIPO\" -create"))
    }

    func testSourceArchiveIsDeterministicAndAcceptedByUnzip() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") else {
            throw XCTSkip("unzip is unavailable")
        }
        let fixture = try makeFixture(architecture: .arm64)
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }

        let archive = try PatchSourceArchiveBuilder().build(
            project: fixture.project,
            buildRecord: fixture.record,
            sourceURL: fixture.sourceURL
        )
        let repeated = try PatchSourceArchiveBuilder().build(
            project: fixture.project,
            buildRecord: fixture.record,
            sourceURL: fixture.sourceURL
        )
        XCTAssertEqual(repeated, archive)
        XCTAssertEqual(archive.filename, "FixturePatchSource.zip")
        let archiveURL = fixture.workspace.appending(path: archive.filename)
        try archive.contents.write(to: archiveURL)

        let validation = try run("/usr/bin/unzip", arguments: ["-t", archiveURL.path])
        XCTAssertEqual(validation.status, 0, validation.output)
        let listing = try run("/usr/bin/unzip", arguments: ["-Z1", archiveURL.path])
        XCTAssertEqual(listing.status, 0, listing.output)
        XCTAssertEqual(
            Set(listing.output.split(whereSeparator: \.isNewline).map(String.init)),
            Set([
                "FixturePatchSource/patch.json",
                "FixturePatchSource/MachPatchGenerated.m",
                "FixturePatchSource/build.sh",
                "FixturePatchSource/README.md",
            ])
        )
    }

    func testDebianPackageContainsDylibFilterAndDeterministicMetadata() throws {
        let fixture = try makeFixture(architecture: .arm64)
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }

        let package = try DebianPackageBuilder().build(
            project: fixture.project,
            buildRecord: fixture.record,
            dylibURL: fixture.dylibURL
        )
        let members = try parseAr(package.contents)

        XCTAssertEqual(package.filename, "FixturePatch.deb")
        XCTAssertEqual(
            package.packageIdentifier,
            "com.example.fixture.machpatch.fixturepatch"
        )
        XCTAssertEqual(members.keys.sorted(), ["control.tar", "data.tar", "debian-binary"])
        XCTAssertEqual(members["debian-binary"], Data("2.0\n".utf8))

        let controlFiles = try parseTar(try XCTUnwrap(members["control.tar"]))
        let control = try XCTUnwrap(
            String(data: try XCTUnwrap(controlFiles["./control"]), encoding: .utf8))
        XCTAssertTrue(control.contains("Package: com.example.fixture.machpatch.fixturepatch"))
        XCTAssertTrue(control.contains("Architecture: iphoneos-arm64"))

        let dataFiles = try parseTar(try XCTUnwrap(members["data.tar"]))
        let base = "./Library/MobileSubstrate/DynamicLibraries"
        XCTAssertEqual(dataFiles["\(base)/FixturePatch.dylib"], Data("fixture dylib".utf8))
        let plist = try XCTUnwrap(
            String(data: try XCTUnwrap(dataFiles["\(base)/FixturePatch.plist"]), encoding: .utf8)
        )
        XCTAssertTrue(plist.contains("\"com.example.fixture\""))

        let repeated = try DebianPackageBuilder().build(
            project: fixture.project,
            buildRecord: fixture.record,
            dylibURL: fixture.dylibURL
        )
        XCTAssertEqual(repeated, package)
    }

    func testDebianPackageRejectsUnresolvedArchitectureMetadataAndMissingBundleID() throws {
        let universal = try makeFixture(architecture: .universal)
        defer { try? FileManager.default.removeItem(at: universal.workspace) }

        XCTAssertThrowsError(
            try DebianPackageBuilder().build(
                project: universal.project,
                buildRecord: universal.record,
                dylibURL: universal.dylibURL
            )
        ) {
            XCTAssertEqual(
                $0 as? PatchPackagingError,
                .unsupportedDebianArchitecture(.universal)
            )
        }

        let missingBundle = try makeFixture(architecture: .arm64, bundleIdentifier: nil)
        defer { try? FileManager.default.removeItem(at: missingBundle.workspace) }

        XCTAssertThrowsError(
            try DebianPackageBuilder().build(
                project: missingBundle.project,
                buildRecord: missingBundle.record,
                dylibURL: missingBundle.dylibURL
            )
        ) {
            XCTAssertEqual($0 as? PatchPackagingError, .bundleIdentifierRequired)
        }
    }

    func testDebianPackageIsAcceptedByDpkgDebWhenInstalled() throws {
        let candidates = [
            "/opt/homebrew/bin/dpkg-deb",
            "/usr/local/bin/dpkg-deb",
            "/usr/bin/dpkg-deb",
        ]
        guard let dpkgDeb = candidates.first(where: FileManager.default.isExecutableFile(atPath:))
        else {
            throw XCTSkip("dpkg-deb is not installed")
        }
        let fixture = try makeFixture(architecture: .arm64)
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let package = try DebianPackageBuilder().build(
            project: fixture.project,
            buildRecord: fixture.record,
            dylibURL: fixture.dylibURL
        )
        let packageURL = fixture.workspace.appending(path: package.filename)
        try package.contents.write(to: packageURL)

        let result = try run(dpkgDeb, arguments: ["--info", packageURL.path])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Package: com.example.fixture.machpatch.fixturepatch"))
        XCTAssertTrue(result.output.contains("Architecture: iphoneos-arm64"))
    }

    func testSourceBundleBuildScriptProducesArm64DylibWithXcode() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("xcrun is unavailable")
        }
        let sdkCheck = try run(
            "/usr/bin/xcrun", arguments: ["--sdk", "iphoneos", "--show-sdk-path"])
        guard sdkCheck.status == 0 else { throw XCTSkip("The iPhoneOS SDK is unavailable") }
        let fixture = try makeFixture(architecture: .arm64)
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try Data(
            "#import <Foundation/Foundation.h>\n__attribute__((constructor)) static void MachPatchFixture(void) {}\n"
                .utf8
        ).write(to: fixture.sourceURL)
        let bundle = try PatchSourceBundleBuilder().build(
            project: fixture.project,
            buildRecord: fixture.record,
            sourceURL: fixture.sourceURL
        )
        let exportURL = fixture.workspace.appending(path: bundle.directoryName)
        try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
        for file in bundle.files {
            try file.contents.write(to: exportURL.appending(path: file.relativePath))
        }

        let build = try run("/bin/sh", arguments: [exportURL.appending(path: "build.sh").path])
        XCTAssertEqual(build.status, 0, build.output)
        let outputURL = exportURL.appending(path: "FixturePatch.dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let architectures = try run(
            "/usr/bin/xcrun",
            arguments: ["lipo", "-archs", outputURL.path]
        )
        XCTAssertEqual(architectures.status, 0, architectures.output)
        XCTAssertEqual(
            architectures.output.trimmingCharacters(in: .whitespacesAndNewlines), "arm64")
    }

    private func makeFixture(
        architecture: PatchBuildOutputArchitecture,
        bundleIdentifier: String? = "com.example.fixture"
    ) throws -> PackagingFixture {
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MachPatchPackagerTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sourceURL = workspace.appending(path: "MachPatchGenerated.m")
        let dylibURL = workspace.appending(path: "FixturePatch.dylib")
        try Data("// generated fixture\n".utf8).write(to: sourceURL)
        try Data("fixture dylib".utf8).write(to: dylibURL)
        let project = PatchProject(
            projectName: "Fixture Patch",
            target: PatchTargetIdentity(
                bundleIdentifier: bundleIdentifier,
                executableName: "Fixture",
                executableSHA256: String(repeating: "a", count: 64),
                selectedSlice: PatchSelectedSlice(architecture: .arm64, cpuSubtype: 0),
                minimumIOSVersion: "15.0"
            ),
            build: PatchBuildConfiguration(
                architectureMode: architecture == .universal ? .universal : .automatic,
                minimumIOSVersion: "15.0",
                outputName: "FixturePatch",
                enableARC: true
            ),
            patches: []
        )
        let record = PatchBuildRecord(
            projectName: project.projectName,
            architecture: architecture,
            minimumIOSVersion: project.build.minimumIOSVersion,
            installName: "@rpath/FixturePatch.dylib",
            sourcePath: sourceURL.path,
            outputPath: dylibURL.path,
            recordPath: workspace.appending(path: "MachPatchBuild.json").path,
            toolchain: AppleToolchain(
                developerDirectory: "/Applications/Xcode.app/Contents/Developer",
                xcodeVersion: "Xcode 26.0",
                clangPath: "/usr/bin/clang",
                clangVersion: "Apple clang",
                lipoPath: "/usr/bin/lipo",
                nmPath: "/usr/bin/nm",
                sdkPath: "/Applications/Xcode.app/iPhoneOS.sdk",
                sdkVersion: "26.0"
            ),
            architectureResolution: BuildArchitectureResolution(
                requestedMode: architecture == .universal ? .universal : .automatic,
                outputArchitecture: architecture,
                slices: architecture == .universal ? [.arm64, .arm64e] : [.arm64],
                targetArchitecture: .arm64,
                targetCPUSubtype: 0,
                targetArm64eABI: nil,
                reason: "Test resolution"
            ),
            capabilityProbes: [],
            slices: [],
            symbolChecks: [],
            merge: nil
        )
        return PackagingFixture(
            workspace: workspace,
            sourceURL: sourceURL,
            dylibURL: dylibURL,
            project: project,
            record: record
        )
    }

    private func parseAr(_ data: Data) throws -> [String: Data] {
        XCTAssertEqual(data.prefix(8), Data("!<arch>\n".utf8))
        var offset = 8
        var members: [String: Data] = [:]
        while offset < data.count {
            guard offset + 60 <= data.count else { throw ParserError.invalidArchive }
            let header = data.subdata(in: offset..<(offset + 60))
            let name = String(decoding: header.prefix(16), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let sizeText = String(decoding: header[48..<58], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText), offset + 60 + size <= data.count else {
                throw ParserError.invalidArchive
            }
            let contentStart = offset + 60
            members[name] = data.subdata(in: contentStart..<(contentStart + size))
            offset = contentStart + size + (size.isMultiple(of: 2) ? 0 : 1)
        }
        return members
    }

    private func parseTar(_ data: Data) throws -> [String: Data] {
        var offset = 0
        var files: [String: Data] = [:]
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) { break }
            let nameBytes = header.prefix(100).prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let sizeText = String(decoding: header[124..<136].prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 8) else { throw ParserError.invalidArchive }
            let contentStart = offset + 512
            guard contentStart + size <= data.count else { throw ParserError.invalidArchive }
            if header[156] != Character("5").asciiValue {
                files[name] = data.subdata(in: contentStart..<(contentStart + size))
            }
            offset = contentStart + ((size + 511) / 512) * 512
        }
        return files
    }

    private func run(_ executable: String, arguments: [String]) throws -> (
        status: Int32, output: String
    ) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output =
            String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        return (process.terminationStatus, output)
    }
}

private struct PackagingFixture {
    let workspace: URL
    let sourceURL: URL
    let dylibURL: URL
    let project: PatchProject
    let record: PatchBuildRecord
}

private enum ParserError: Error {
    case invalidArchive
}
