import CryptoKit
import Foundation
import MachPatchCore
import XCTest

@testable import MachPatchAnalyzer

final class InputResolverTests: XCTestCase {
    func testResolvesDirectMachOAndCalculatesSHA256() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appending(path: "Fixture Binary")
        let executableData = machOFixtureData()
        try executableData.write(to: executableURL)

        let expectedHash = SHA256.hash(data: executableData)
            .map { String(format: "%02x", $0) }
            .joined()

        try InputResolver().withResolvedTarget(at: executableURL) { target in
            XCTAssertEqual(target.sourceType, .machO)
            XCTAssertEqual(target.sourcePath, executableURL.path)
            XCTAssertNil(target.bundlePath)
            XCTAssertEqual(target.executableName, "Fixture Binary")
            XCTAssertEqual(target.executablePath, executableURL.path)
            XCTAssertEqual(target.sha256, expectedHash)
        }
    }

    func testResolvesApplicationWithSpacesInPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationURL = root.appending(path: "Fixture App.app", directoryHint: .isDirectory)
        try makeApplication(at: applicationURL, executableName: "Fixture Binary")

        try InputResolver().withResolvedTarget(at: applicationURL) { target in
            XCTAssertEqual(target.sourceType, .applicationBundle)
            XCTAssertEqual(target.bundleIdentifier, "com.example.fixture")
            XCTAssertEqual(target.displayName, "Fixture App")
            XCTAssertEqual(target.minimumOSVersion, "15.0")
            XCTAssertEqual(target.supportedPlatforms, ["iPhoneOS"])
            XCTAssertEqual(target.executableName, "Fixture Binary")
            XCTAssertEqual(target.bundlePath, applicationURL.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.executablePath))
            XCTAssertEqual(target.images.map(\.kind), [.mainExecutable])
            XCTAssertEqual(target.primaryImage.sha256, target.sha256)
        }
    }

    func testResolvesStandaloneFrameworkAndCalculatesIndependentImageIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frameworkURL = root.appending(
            path: "Fixture Kit.framework", directoryHint: .isDirectory)
        try makeBundle(
            at: frameworkURL,
            executableName: "Fixture Kit",
            bundleIdentifier: "com.example.fixture-kit",
            displayName: "Fixture Kit"
        )

        try InputResolver().withResolvedTarget(at: frameworkURL) { target in
            XCTAssertEqual(target.sourceType, .frameworkBundle)
            XCTAssertEqual(target.bundlePath, frameworkURL.path)
            XCTAssertEqual(target.bundleIdentifier, "com.example.fixture-kit")
            XCTAssertEqual(target.executableName, "Fixture Kit")
            XCTAssertEqual(target.images.count, 1)

            let image = try XCTUnwrap(target.images.first)
            XCTAssertEqual(image.kind, .standaloneFramework)
            XCTAssertEqual(image.relativePath, "Fixture Kit")
            XCTAssertEqual(image.bundlePath, frameworkURL.path)
            XCTAssertEqual(image.sha256, target.sha256)
            XCTAssertTrue(image.hasBundleMetadata)
        }
    }

    func testEnumeratesEmbeddedFrameworksExtensionsAndNestedFrameworksInStableOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationURL = root.appending(path: "Host.app", directoryHint: .isDirectory)
        try makeApplication(at: applicationURL, executableName: "Host")

        let frameworksURL = applicationURL.appending(
            path: "Frameworks", directoryHint: .isDirectory)
        try makeBundle(
            at: frameworksURL.appending(path: "Zeta.framework", directoryHint: .isDirectory),
            executableName: "Zeta",
            bundleIdentifier: "com.example.zeta",
            displayName: "Zeta"
        )
        let alphaURL = frameworksURL.appending(
            path: "Alpha.framework", directoryHint: .isDirectory)
        try makeBundle(
            at: alphaURL,
            executableName: "Alpha",
            bundleIdentifier: "com.example.alpha",
            displayName: "Alpha"
        )

        let extensionURL = applicationURL.appending(
            path: "PlugIns/Widget.appex", directoryHint: .isDirectory)
        try makeBundle(
            at: extensionURL,
            executableName: "Widget",
            bundleIdentifier: "com.example.fixture.widget",
            displayName: "Widget"
        )
        try makeBundle(
            at: extensionURL.appending(
                path: "Frameworks/Nested.framework", directoryHint: .isDirectory),
            executableName: "Nested",
            bundleIdentifier: "com.example.nested",
            displayName: "Nested"
        )

        try InputResolver().withResolvedTarget(at: applicationURL) { target in
            XCTAssertEqual(
                target.images.map(\.relativePath),
                [
                    "Host",
                    "Frameworks/Alpha.framework/Alpha",
                    "Frameworks/Zeta.framework/Zeta",
                    "PlugIns/Widget.appex/Frameworks/Nested.framework/Nested",
                    "PlugIns/Widget.appex/Widget",
                ]
            )
            XCTAssertEqual(
                target.images.map(\.kind),
                [
                    .mainExecutable,
                    .dynamicFramework,
                    .dynamicFramework,
                    .dynamicFramework,
                    .appExtension,
                ]
            )
            XCTAssertEqual(target.images.map(\.id).count, Set(target.images.map(\.id)).count)
            XCTAssertEqual(
                target.images.first(where: { $0.executableName == "Alpha" })?.bundleIdentifier,
                "com.example.alpha"
            )
            XCTAssertTrue(target.imageDiscoveryIssues.isEmpty)
        }
    }

    func testReportsMalformedEmbeddedFrameworkWithoutDiscardingHost() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationURL = root.appending(path: "Host.app", directoryHint: .isDirectory)
        try makeApplication(at: applicationURL, executableName: "Host")
        let frameworkURL = applicationURL.appending(
            path: "Frameworks/Broken.framework", directoryHint: .isDirectory)
        try makeBundle(
            at: frameworkURL,
            executableName: "Broken",
            bundleIdentifier: "com.example.broken",
            displayName: "Broken",
            writeExecutable: false
        )

        try InputResolver().withResolvedTarget(at: applicationURL) { target in
            XCTAssertEqual(target.images.map(\.executableName), ["Host"])
            XCTAssertEqual(target.imageDiscoveryIssues.count, 1)
            let issue = try XCTUnwrap(target.imageDiscoveryIssues.first)
            XCTAssertEqual(issue.kind, .dynamicFramework)
            XCTAssertEqual(issue.relativeBundlePath, "Frameworks/Broken.framework")
            XCTAssertTrue(issue.message.contains("Broken.framework/Broken"))
        }
    }

    func testRejectsStandaloneFrameworkWithMissingExecutable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frameworkURL = root.appending(
            path: "Broken.framework", directoryHint: .isDirectory)
        try makeBundle(
            at: frameworkURL,
            executableName: "Broken",
            bundleIdentifier: "com.example.broken",
            displayName: "Broken",
            writeExecutable: false
        )

        XCTAssertThrowsError(try InputResolver().withResolvedTarget(at: frameworkURL) { _ in }) {
            error in
            XCTAssertEqual(
                error as? InputResolutionError,
                .executableNotFound(frameworkURL.appending(path: "Broken").path)
            )
        }
    }

    func testResolvesIPAAndAlwaysCleansTemporaryWorkspace() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveRoot = root.appending(path: "Archive Root", directoryHint: .isDirectory)
        let payloadURL = archiveRoot.appending(path: "Payload", directoryHint: .isDirectory)
        let applicationURL = payloadURL.appending(path: "Fixture.app", directoryHint: .isDirectory)
        try makeApplication(at: applicationURL, executableName: "Fixture")
        let archiveURL = root.appending(path: "Fixture With Spaces.ipa")
        try createZip(from: payloadURL, at: archiveURL)

        let workspaceParent = root.appending(path: "Workspaces", directoryHint: .isDirectory)
        let resolver = InputResolver(temporaryDirectoryURL: workspaceParent)
        var extractedExecutablePath: String?

        try resolver.withResolvedTarget(at: archiveURL) { target in
            extractedExecutablePath = target.executablePath
            XCTAssertEqual(target.sourceType, .ipa)
            XCTAssertEqual(target.sourcePath, archiveURL.path)
            XCTAssertEqual(target.executableName, "Fixture")
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.executablePath))
            XCTAssertEqual(try workspaceContents(at: workspaceParent).count, 1)
        }

        XCTAssertNotNil(extractedExecutablePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractedExecutablePath ?? ""))
        XCTAssertEqual(try workspaceContents(at: workspaceParent), [])
    }

    func testCleansTemporaryWorkspaceWhenBodyThrows() throws {
        enum ExpectedError: Error { case stop }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveRoot = root.appending(path: "Archive", directoryHint: .isDirectory)
        let payloadURL = archiveRoot.appending(path: "Payload", directoryHint: .isDirectory)
        try makeApplication(
            at: payloadURL.appending(path: "Fixture.app", directoryHint: .isDirectory),
            executableName: "Fixture"
        )
        let archiveURL = root.appending(path: "Fixture.ipa")
        try createZip(from: payloadURL, at: archiveURL)

        let workspaceParent = root.appending(path: "Workspaces", directoryHint: .isDirectory)
        let resolver = InputResolver(temporaryDirectoryURL: workspaceParent)

        XCTAssertThrowsError(
            try resolver.withResolvedTarget(at: archiveURL) { _ in
                throw ExpectedError.stop
            }
        ) { error in
            XCTAssertTrue(error is ExpectedError)
        }
        XCTAssertEqual(try workspaceContents(at: workspaceParent), [])
    }

    func testRejectsIPAMissingPayloadAndCleansWorkspace() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveRoot = root.appending(path: "Archive", directoryHint: .isDirectory)
        let wrongRoot = archiveRoot.appending(path: "NotPayload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wrongRoot, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: wrongRoot.appending(path: "file.txt"))
        let archiveURL = root.appending(path: "MissingPayload.ipa")
        try createZip(from: wrongRoot, at: archiveURL)

        let workspaceParent = root.appending(path: "Workspaces", directoryHint: .isDirectory)
        let resolver = InputResolver(temporaryDirectoryURL: workspaceParent)

        XCTAssertThrowsError(try resolver.withResolvedTarget(at: archiveURL) { _ in }) { error in
            XCTAssertEqual(error as? InputResolutionError, .missingPayload)
        }
        XCTAssertEqual(try workspaceContents(at: workspaceParent), [])
    }

    func testRejectsInvalidArchiveAndCleansWorkspace() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appending(path: "Invalid.ipa")
        try Data("not a ZIP archive".utf8).write(to: archiveURL)
        let workspaceParent = root.appending(path: "Workspaces", directoryHint: .isDirectory)

        XCTAssertThrowsError(
            try InputResolver(temporaryDirectoryURL: workspaceParent)
                .withResolvedTarget(at: archiveURL) { _ in }
        ) { error in
            guard case .unsafeArchive = error as? InputResolutionError else {
                return XCTFail("Expected unsafeArchive, received \(error)")
            }
        }
        XCTAssertEqual(try workspaceContents(at: workspaceParent), [])
    }

    func testRejectsIPAWithMultipleApplications() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveRoot = root.appending(path: "Archive", directoryHint: .isDirectory)
        let payloadURL = archiveRoot.appending(path: "Payload", directoryHint: .isDirectory)
        try makeApplication(
            at: payloadURL.appending(path: "First.app", directoryHint: .isDirectory),
            executableName: "First"
        )
        try makeApplication(
            at: payloadURL.appending(path: "Second.app", directoryHint: .isDirectory),
            executableName: "Second"
        )
        let archiveURL = root.appending(path: "Multiple.ipa")
        try createZip(from: payloadURL, at: archiveURL)

        XCTAssertThrowsError(try InputResolver().withResolvedTarget(at: archiveURL) { _ in }) {
            error in
            XCTAssertEqual(
                error as? InputResolutionError,
                .multipleApplications(["First.app", "Second.app"])
            )
        }
    }

    func testRejectsMissingAndUnsafeBundleExecutableValues() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appending(path: "Missing.app", directoryHint: .isDirectory)
        try makeApplication(at: missingURL, executableName: nil)

        XCTAssertThrowsError(try InputResolver().withResolvedTarget(at: missingURL) { _ in }) {
            error in
            XCTAssertEqual(
                error as? InputResolutionError,
                .missingBundleExecutable(missingURL.appending(path: "Info.plist").path)
            )
        }

        let unsafeURL = root.appending(path: "Unsafe.app", directoryHint: .isDirectory)
        try makeApplication(at: unsafeURL, executableName: "../Escape")
        XCTAssertThrowsError(try InputResolver().withResolvedTarget(at: unsafeURL) { _ in }) {
            error in
            XCTAssertEqual(error as? InputResolutionError, .unsafeExecutableName("../Escape"))
        }
    }

    func testRejectsNonMachOFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "NotMachO")
        try Data("not a Mach-O".utf8).write(to: fileURL)

        XCTAssertThrowsError(try InputResolver().withResolvedTarget(at: fileURL) { _ in }) {
            error in
            XCTAssertEqual(error as? InputResolutionError, .unsupportedInput(fileURL.path))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "MachPatchTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func makeApplication(at url: URL, executableName: String?) throws {
        try makeBundle(
            at: url,
            executableName: executableName,
            bundleIdentifier: "com.example.fixture",
            displayName: "Fixture App"
        )
    }

    private func makeBundle(
        at url: URL,
        executableName: String?,
        bundleIdentifier: String,
        displayName: String,
        writeExecutable: Bool = true
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleDisplayName": displayName,
            "MinimumOSVersion": "15.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
        ]
        if let executableName {
            info["CFBundleExecutable"] = executableName
        }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plistData.write(to: url.appending(path: "Info.plist"))

        if writeExecutable, let executableName, !executableName.contains("/") {
            try machOFixtureData().write(to: url.appending(path: executableName))
        }
    }

    private func machOFixtureData() -> Data {
        Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00, 0x00, 0x00])
    }

    private func createZip(from sourceURL: URL, at archiveURL: URL) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.currentDirectoryURL = sourceURL.deletingLastPathComponent()
        process.arguments = [
            "-c", "-k", "--keepParent", sourceURL.lastPathComponent, archiveURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ditto failed"
            throw NSError(
                domain: "InputResolverTests", code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
        }
    }

    private func workspaceContents(at url: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
    }
}
