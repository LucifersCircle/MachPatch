import Foundation
import MachPatchAnalyzer
import MachPatchBuilder
import MachPatchCore
import MachPatchPackager
import MachPatchVerifier
import XCTest

final class RuntimeFixtureTests: XCTestCase {
    func testFixtureSupportsEndToEndAppAndLateFrameworkWorkflows() throws {
        try requireIPhoneOSSDK()

        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-RuntimeFixtureTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fixtureOutput = workspace.appending(path: "Fixture", directoryHint: .isDirectory)
        try runFixtureBuild(outputDirectory: fixtureOutput)
        let appURL = fixtureOutput.appending(
            path: "MachPatchRuntimeFixture.app",
            directoryHint: .isDirectory
        )

        try InputResolver().withResolvedTarget(at: appURL) { target in
            XCTAssertEqual(target.bundleIdentifier, "com.machpatch.runtime-fixture")
            XCTAssertEqual(target.images.count, 2)

            let mainImage = try XCTUnwrap(target.images.first { $0.kind == .mainExecutable })
            let frameworkImage = try XCTUnwrap(
                target.images.first { $0.kind == .dynamicFramework }
            )
            XCTAssertEqual(frameworkImage.executableName, "MPFixtureKit")

            let analyzer = ObjectiveCAnalyzer()
            let inspector = MachOInspector()
            let mainAnalysis = try analyzer.analyze(target, image: mainImage)
            let frameworkAnalysis = try analyzer.analyze(target, image: frameworkImage)
            let mainInspection = MachOInspection(
                target: target,
                image: mainImage,
                slices: try inspector.inspect(at: mainImage.executableURL)
            )
            let frameworkInspection = MachOInspection(
                target: target,
                image: frameworkImage,
                slices: try inspector.inspect(at: frameworkImage.executableURL)
            )

            XCTAssertNotNil(
                mainAnalysis.metadata.classes.first { $0.name == "MPFixtureController" }
            )
            XCTAssertNotNil(
                frameworkAnalysis.metadata.classes.first { $0.name == "MPFixtureLateTarget" }
            )
            XCTAssertTrue(
                frameworkAnalysis.metadata.categories.contains {
                    $0.className == "NSObject" && $0.name == "MPFixtureRuntimeExtras"
                }
            )

            let mainProject = try makeMainProject(
                target: target,
                image: mainImage,
                inspection: mainInspection,
                analysis: mainAnalysis
            )
            let mainBuildDirectory = workspace.appending(
                path: "MainPatch",
                directoryHint: .isDirectory
            )
            let mainRecord = try PatchDylibBuilder().build(
                mainProject,
                outputDirectory: mainBuildDirectory
            )
            let mainDylibURL = URL(filePath: mainRecord.outputPath)
            let mainReport = try LiveContainerVerifier().verify(
                dylibURL: mainDylibURL,
                targetInspection: mainInspection
            )
            XCTAssertTrue(
                mainReport.isReadyForLiveContainerTesting,
                mainReport.blockingFailures.map(\.message).joined(separator: "\n")
            )

            let sourceArchive = try PatchSourceArchiveBuilder().build(
                project: mainProject,
                buildRecord: mainRecord,
                sourceURL: URL(filePath: mainRecord.sourcePath)
            )
            let debianPackage = try DebianPackageBuilder().build(
                project: mainProject,
                buildRecord: mainRecord,
                dylibURL: mainDylibURL
            )
            XCTAssertGreaterThan(sourceArchive.contents.count, 0)
            XCTAssertGreaterThan(debianPackage.contents.count, 0)

            let frameworkProject = try makeFrameworkProject(
                target: target,
                image: frameworkImage,
                inspection: frameworkInspection,
                analysis: frameworkAnalysis
            )
            let frameworkBuildDirectory = workspace.appending(
                path: "FrameworkPatch",
                directoryHint: .isDirectory
            )
            let frameworkRecord = try PatchDylibBuilder().build(
                frameworkProject,
                outputDirectory: frameworkBuildDirectory
            )
            let frameworkReport = try LiveContainerVerifier().verify(
                dylibURL: URL(filePath: frameworkRecord.outputPath),
                targetInspection: frameworkInspection
            )
            XCTAssertTrue(
                frameworkReport.isReadyForLiveContainerTesting,
                frameworkReport.blockingFailures.map(\.message).joined(separator: "\n")
            )
        }
    }

    private func makeMainProject(
        target: ResolvedTarget,
        image: ResolvedImage,
        inspection: MachOInspection,
        analysis: ObjectiveCAnalysis
    ) throws -> PatchProject {
        let className = "MPFixtureController"
        return PatchProject(
            projectName: "Runtime Fixture Main Patch",
            target: try targetIdentity(
                target: target,
                image: image,
                inspection: inspection
            ),
            build: PatchBuildConfiguration(
                architectureMode: .automatic,
                minimumIOSVersion: "15.0",
                outputName: "RuntimeFixtureMainPatch",
                enableARC: true
            ),
            patches: [
                try patch(
                    id: "09612F50-A200-470C-AD23-16E22C574833",
                    className: className,
                    selector: "featureEnabled",
                    action: .returnBoolean(true),
                    analysis: analysis
                ),
                try patch(
                    id: "9444BA88-214C-4144-8793-981A5A625D20",
                    className: className,
                    selector: "scoreForLevel:",
                    action: .callOriginal,
                    analysis: analysis
                ),
                try patch(
                    id: "AD22D580-A31F-4B3A-874E-4C026670AA10",
                    className: className,
                    selector: "greetingForName:",
                    action: .returnString("Patched hello"),
                    analysis: analysis
                ),
                try patch(
                    id: "42E3801B-1D3B-481B-8D0E-F64823D7C917",
                    className: className,
                    selector: "recordFlag:object:",
                    action: .logArguments,
                    analysis: analysis
                ),
                try patch(
                    id: "9309455C-77E0-451C-ABFC-1AF08A85782C",
                    className: className,
                    selector: "insetRect:",
                    action: .callOriginal,
                    analysis: analysis
                ),
                try patch(
                    id: "D6F9150A-0DD5-4C76-AFE9-FCC54423D364",
                    className: className,
                    selector: "clampedRange:",
                    action: .callOriginal,
                    analysis: analysis
                ),
                try patch(
                    id: "81F725A2-0B88-4E61-BAF4-9873C4D401D2",
                    className: className,
                    selector: "applyIntegerBlock:toValue:",
                    action: .callOriginal,
                    analysis: analysis
                ),
                try patch(
                    id: "21CC62DF-9263-4341-816A-57FDF9F44AD4",
                    className: className,
                    selector: "categoryValue",
                    action: .returnBoolean(true),
                    analysis: analysis
                ),
            ]
        )
    }

    private func makeFrameworkProject(
        target: ResolvedTarget,
        image: ResolvedImage,
        inspection: MachOInspection,
        analysis: ObjectiveCAnalysis
    ) throws -> PatchProject {
        let className = "MPFixtureLateTarget"
        return PatchProject(
            projectName: "Runtime Fixture Late Framework Patch",
            target: try targetIdentity(
                target: target,
                image: image,
                inspection: inspection
            ),
            build: PatchBuildConfiguration(
                architectureMode: .automatic,
                minimumIOSVersion: "15.0",
                outputName: "RuntimeFixtureFrameworkPatch",
                enableARC: true
            ),
            patches: [
                try patch(
                    id: "45EEDAC4-A071-4A06-90DB-9AA45E49A334",
                    className: className,
                    selector: "lateValue",
                    action: .returnBoolean(true),
                    analysis: analysis
                ),
                try patch(
                    id: "5F457847-0D27-446F-80BB-4ED4E8EF75AC",
                    className: className,
                    selector: "lateInteger",
                    action: .returnSignedInteger(42),
                    analysis: analysis
                ),
                try patch(
                    id: "F6C62D87-7190-4CF4-85BD-13F92964BBA2",
                    className: className,
                    selector: "lateGreeting:",
                    action: .returnString("Loaded late"),
                    analysis: analysis
                ),
                try patch(
                    id: "CB9B6FD1-EC5E-4D7C-B15B-E38982F4BED3",
                    className: className,
                    selector: "lateRect:",
                    action: .callOriginal,
                    analysis: analysis
                ),
                try patch(
                    id: "0E56E8B9-7C87-4218-BE6B-5F08CD968567",
                    className: className,
                    selector: "lateRange:",
                    action: .callOriginal,
                    analysis: analysis
                ),
                try patch(
                    id: "F031F2AC-1CC1-489D-86EC-AF2E3705A5B1",
                    className: className,
                    selector: "lateBlockResult:",
                    action: .callOriginal,
                    analysis: analysis
                ),
                try patch(
                    id: "291AE4E9-FE94-4DC7-895F-AF4543D7E76B",
                    className: "NSObject",
                    selector: "mp_fixtureCategoryFlag",
                    action: .returnBoolean(true),
                    analysis: analysis
                ),
            ]
        )
    }

    private func targetIdentity(
        target: ResolvedTarget,
        image: ResolvedImage,
        inspection: MachOInspection
    ) throws -> PatchTargetIdentity {
        let slice = try XCTUnwrap(inspection.slices.first)
        return PatchTargetIdentity(
            bundleIdentifier: target.bundleIdentifier,
            executableName: target.executableName,
            executableSHA256: target.sha256,
            selectedImage: PatchImageIdentity(image: image),
            selectedSlice: PatchSelectedSlice(
                architecture: slice.architecture,
                cpuSubtype: slice.cpuSubtype
            ),
            minimumIOSVersion: target.minimumOSVersion
        )
    }

    private func patch(
        id: String,
        className: String,
        selector: String,
        action: PatchAction,
        analysis: ObjectiveCAnalysis
    ) throws -> MethodPatch {
        let method = try method(named: selector, on: className, in: analysis)
        return MethodPatch(
            id: id,
            enabled: true,
            className: className,
            selector: selector,
            methodKind: method.kind,
            expectedTypeEncoding: try XCTUnwrap(method.typeEncoding),
            action: action
        )
    }

    private func method(
        named selector: String,
        on className: String,
        in analysis: ObjectiveCAnalysis
    ) throws -> ObjectiveCMethod {
        if let objectClass = analysis.metadata.classes.first(where: { $0.name == className }),
            let method = (objectClass.instanceMethods + objectClass.classMethods).first(where: {
                $0.selector == selector
            })
        {
            return method
        }
        for category in analysis.metadata.categories where category.className == className {
            if let method = (category.instanceMethods + category.classMethods).first(where: {
                $0.selector == selector
            }) {
                return method
            }
        }
        XCTFail("Missing \(className) \(selector) in runtime fixture analysis")
        throw RuntimeFixtureTestError.missingMethod("\(className) \(selector)")
    }

    private func requireIPhoneOSSDK() throws {
        let result = try run(
            executableURL: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["--sdk", "iphoneos", "--show-sdk-path"]
        )
        if result.status != 0 {
            throw XCTSkip("The runtime fixture requires an installed iPhoneOS SDK.")
        }
    }

    private func runFixtureBuild(outputDirectory: URL) throws {
        let fixtureDirectory = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/RuntimeFixture", directoryHint: .isDirectory)
        let result = try run(
            executableURL: fixtureDirectory.appending(path: "build.sh"),
            arguments: [outputDirectory.path]
        )
        XCTAssertEqual(result.status, 0, result.output)
        guard result.status == 0 else {
            throw RuntimeFixtureTestError.buildFailed(result.output)
        }
    }

    private func run(executableURL: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return ProcessResult(status: process.terminationStatus, output: output)
    }
}

private struct ProcessResult {
    let status: Int32
    let output: String
}

private enum RuntimeFixtureTestError: Error {
    case buildFailed(String)
    case missingMethod(String)
}
