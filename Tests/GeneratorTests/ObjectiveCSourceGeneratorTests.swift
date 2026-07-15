import Foundation
import MachPatchCore
import XCTest

@testable import MachPatchGenerator

final class ObjectiveCSourceGeneratorTests: XCTestCase {
    func testExampleProjectMatchesGeneratedSourceSnapshot() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try PatchProjectCodec.decode(
            Data(contentsOf: repositoryRoot.appending(path: "Examples/ExamplePatch.json"))
        )
        let snapshotURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "ExamplePatch.m",
                withExtension: "snap",
                subdirectory: "Snapshots"
            )
        )
        let expected = try String(contentsOf: snapshotURL, encoding: .utf8)

        XCTAssertEqual(try generate(project), expected)
    }

    func testGeneratesEveryVersionOneActionAndRuntimeCoordinator() throws {
        let source = try generate(makeProject(patches: allActionPatches()))

        XCTAssertTrue(source.hasSuffix("\n"))
        XCTAssertTrue(source.contains("#import <objc/runtime.h>"))
        XCTAssertTrue(
            source.contains("static BOOL MPPatch_0_FixtureManager_featureEnabled_Replacement"))
        XCTAssertTrue(source.contains("return YES;"))
        XCTAssertTrue(source.contains("return (long long)-42LL;"))
        XCTAssertTrue(source.contains("return (unsigned long long)42ULL;"))
        XCTAssertTrue(source.contains("return nil;"))
        XCTAssertTrue(source.contains("return @\"Fixture\";"))
        XCTAssertTrue(source.contains("[MachPatch] Invoked %@"))
        XCTAssertTrue(source.contains("argument 1 = %d"))
        XCTAssertTrue(source.contains("returned %d"))
        XCTAssertTrue(source.contains("_Original(self, _cmd"))
        XCTAssertTrue(source.contains("object_getClass((id)cls)"))
        XCTAssertTrue(source.contains("strcmp(encoding, \"B@:\")"))
        XCTAssertTrue(source.contains("MPScheduleRetry(1.0, NO);"))
        XCTAssertTrue(source.contains("MPScheduleRetry(3.0, NO);"))
        XCTAssertTrue(source.contains("MPScheduleRetry(8.0, YES);"))
        XCTAssertTrue(source.contains("__attribute__((constructor))"))

        XCTAssertFalse(source.contains("MPPatch_0_FixtureManager_featureEnabled_Original"))
        XCTAssertTrue(source.contains("MPPatch_8_FixtureManager_reset_Original"))
    }

    func testGeneratedIdentifiersAreSanitizedScopedAndDeterministic() throws {
        XCTAssertEqual(ObjectiveCIdentifier.sanitize("9 Weird-Class🔥"), "_9_Weird_Class")
        XCTAssertEqual(ObjectiveCIdentifier.sanitize("do:thing:"), "do_thing")
        XCTAssertEqual(ObjectiveCIdentifier.sanitize("🔥🔥"), "value")

        let first = makePatch(
            index: 1,
            className: "A-B",
            selector: "same:",
            encoding: "v24@0:8B16",
            action: .callOriginal
        )
        let second = makePatch(
            index: 2,
            className: "A_B",
            selector: "same:",
            encoding: "v24@0:8B16",
            action: .callOriginal
        )
        let project = makeProject(patches: [first, second])

        let source1 = try generate(project)
        let source2 = try generate(project)
        XCTAssertEqual(source1, source2)
        XCTAssertTrue(source1.contains("MPPatch_0_A_B_same_Replacement"))
        XCTAssertTrue(source1.contains("MPPatch_1_A_B_same_Replacement"))
    }

    func testMapsEverySupportedArgumentABIType() throws {
        let patch = makePatch(
            index: 1,
            selector: "a:b:c:d:e:f:g:h:i:j:k:l:m:n:",
            encoding: "v@:BcCsSiIlLqQ@#:",
            action: .callOriginal
        )

        let source = try generate(makeProject(patches: [patch]))

        for declaration in [
            "BOOL argument0",
            "signed char argument1",
            "unsigned char argument2",
            "short argument3",
            "unsigned short argument4",
            "int argument5",
            "unsigned int argument6",
            "long argument7",
            "unsigned long argument8",
            "long long argument9",
            "unsigned long long argument10",
            "id argument11",
            "Class argument12",
            "SEL argument13",
        ] {
            XCTAssertTrue(source.contains(declaration), declaration)
        }
    }

    func testEscapesRuntimeAndObjectiveCStringLiterals() throws {
        let patch = makePatch(
            index: 1,
            className: "Quoted\"Class",
            selector: "line\\break",
            encoding: "@@:",
            action: .returnString("line\n\"fire🔥")
        )

        let source = try generate(makeProject(patches: [patch]))

        XCTAssertTrue(source.contains("objc_getClass(\"Quoted\\\"Class\")"))
        XCTAssertTrue(source.contains("sel_registerName(\"line\\\\break\")"))
        XCTAssertTrue(source.contains("return @\"line\\n\\\"fire\\360\\237\\224\\245\";"))
    }

    func testMarksRetainedObjectiveCMethodFamilies() throws {
        let retained = makePatch(
            index: 1,
            selector: "copyValue",
            encoding: "@@:",
            action: .callOriginalAndReplace(.nilValue)
        )
        let ordinary = makePatch(
            index: 2,
            selector: "copyingValue",
            encoding: "@@:",
            action: .callOriginal
        )

        let source = try generate(makeProject(patches: [retained, ordinary]))

        XCTAssertTrue(
            source.contains(
                "MPPatch_0_FixtureManager_copyValue_Function)(id, SEL) __attribute__((ns_returns_retained))"
            )
        )
        XCTAssertTrue(
            source.contains(
                "MPPatch_0_FixtureManager_copyValue_Replacement(\n    id self,\n    SEL _cmd\n) __attribute__((ns_returns_retained));"
            )
        )
        XCTAssertFalse(
            source.contains(
                "MPPatch_1_FixtureManager_copyingValue_Function)(id, SEL) __attribute__((ns_returns_retained))"
            )
        )
    }

    func testOmitsDisabledPatchesWithoutRenumberingEnabledProjectIndices() throws {
        let disabled = MethodPatch(
            id: uuid(1),
            enabled: false,
            className: "DisabledClass",
            selector: "disabled",
            methodKind: .instance,
            expectedTypeEncoding: "B@:",
            action: .returnBoolean(false)
        )
        let enabled = makePatch(index: 2)

        let source = try generate(makeProject(patches: [disabled, enabled]))

        XCTAssertFalse(source.contains("DisabledClass"))
        XCTAssertTrue(source.contains("MPPatch_1_FixtureManager_method2_Replacement"))
    }

    func testWriterCreatesAtomicSourceAndRejectsSymlinkDirectory() throws {
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-GeneratorWriter-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundle = try ObjectiveCSourceGenerator().generate(makeProject())
        let output = workspace.appending(path: "Generated", directoryHint: .isDirectory)

        let urls = try GeneratedSourceWriter.write(bundle, to: output)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].lastPathComponent, MachPatchGenerator.generatedSourceFileName)
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), bundle.files[0].contents)

        let actualDirectory = workspace.appending(path: "Actual", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: actualDirectory,
            withIntermediateDirectories: true
        )
        let symlink = workspace.appending(path: "Linked", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: actualDirectory
        )
        XCTAssertThrowsError(try GeneratedSourceWriter.write(bundle, to: symlink)) { error in
            XCTAssertEqual(
                error as? GeneratedSourceWriterError,
                .outputDirectoryIsSymbolicLink(symlink.path)
            )
        }

        let linkedDestinationDirectory = workspace.appending(
            path: "LinkedDestination",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: linkedDestinationDirectory,
            withIntermediateDirectories: true
        )
        let destination = linkedDestinationDirectory.appending(
            path: MachPatchGenerator.generatedSourceFileName
        )
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: workspace.appending(path: "elsewhere")
        )
        XCTAssertThrowsError(
            try GeneratedSourceWriter.write(bundle, to: linkedDestinationDirectory)
        ) { error in
            XCTAssertEqual(
                error as? GeneratedSourceWriterError,
                .destinationIsSymbolicLink(destination.path)
            )
        }
    }

    func testRejectsInvalidProjectBeforeGenerating() {
        let invalid = makePatch(
            index: 1,
            selector: "point",
            encoding: "{Point=dd}@:",
            action: .callOriginal
        )

        XCTAssertThrowsError(
            try ObjectiveCSourceGenerator().generate(makeProject(patches: [invalid]))
        ) { error in
            guard case .invalidProject(let issues) = error as? ObjectiveCSourceGeneratorError else {
                return XCTFail("Expected invalidProject, received \(error)")
            }
            XCTAssertTrue(issues.contains { $0.code == .unsupportedReturnType })
        }
    }

    func testGeneratedSourcePassesHostClangWarningsAsErrors() throws {
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-GeneratorCompile-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundle = try ObjectiveCSourceGenerator().generate(
            makeProject(
                patches: allActionPatches() + [
                    makePatch(
                        index: 12,
                        selector: "a:b:c:d:e:f:g:h:i:j:k:l:m:n:",
                        encoding: "v@:BcCsSiIlLqQ@#:",
                        action: .callOriginal
                    )
                ]
            )
        )
        let sourceURL = try XCTUnwrap(
            GeneratedSourceWriter.write(bundle, to: workspace).first
        )

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = [
            "clang",
            "-fobjc-arc",
            "-fblocks",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-fsyntax-only",
            "-x",
            "objective-c",
            sourceURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
    }

    private func generate(_ project: PatchProject) throws -> String {
        try XCTUnwrap(ObjectiveCSourceGenerator().generate(project).files.first).contents
    }

    private func allActionPatches() -> [MethodPatch] {
        [
            makePatch(index: 0, selector: "featureEnabled", action: .returnBoolean(true)),
            makePatch(
                index: 1,
                selector: "maximumItems",
                encoding: "q@:",
                action: .returnSignedInteger(-42)
            ),
            makePatch(
                index: 2,
                selector: "itemLimit",
                encoding: "Q@:",
                action: .returnUnsignedInteger(42)
            ),
            makePatch(index: 3, selector: "currentObject", encoding: "@@:", action: .returnNil),
            makePatch(
                index: 4,
                selector: "currentStatus",
                methodKind: .class,
                encoding: "@@:",
                action: .returnString("Fixture")
            ),
            makePatch(
                index: 5,
                selector: "refresh",
                encoding: "v@:",
                action: .logInvocation
            ),
            makePatch(
                index: 6,
                selector: "setFlag:",
                encoding: "v24@0:8B16",
                action: .logArguments
            ),
            makePatch(
                index: 7,
                selector: "isPremium",
                action: .logOriginalReturnValue
            ),
            makePatch(index: 8, selector: "reset", encoding: "v@:", action: .callOriginal),
            makePatch(
                index: 9,
                selector: "replacementEnabled",
                action: .callOriginalAndReplace(.boolean(false))
            ),
            makePatch(
                index: 10,
                selector: "newObject",
                encoding: "@@:",
                action: .callOriginalAndReplace(.nilValue)
            ),
            makePatch(
                index: 11,
                selector: "sharedClass",
                encoding: "#@:",
                action: .returnNil
            ),
        ]
    }

    private func makeProject(patches: [MethodPatch]? = nil) -> PatchProject {
        PatchProject(
            projectName: "Generator Fixture",
            target: PatchTargetIdentity(
                bundleIdentifier: "com.example.fixture",
                executableName: "Fixture",
                executableSHA256: String(repeating: "a", count: 64),
                selectedSlice: PatchSelectedSlice(architecture: .arm64, cpuSubtype: 0),
                minimumIOSVersion: "15.0"
            ),
            build: PatchBuildConfiguration(
                architectureMode: .automatic,
                minimumIOSVersion: "15.0",
                outputName: "GeneratorFixture",
                enableARC: true
            ),
            patches: patches ?? [makePatch(index: 0)]
        )
    }

    private func makePatch(
        index: Int,
        className: String = "FixtureManager",
        selector: String? = nil,
        methodKind: ObjectiveCMethodKind = .instance,
        encoding: String = "B@:",
        action: PatchAction = .returnBoolean(true)
    ) -> MethodPatch {
        MethodPatch(
            id: uuid(index + 1),
            enabled: true,
            className: className,
            selector: selector ?? "method\(index)",
            methodKind: methodKind,
            expectedTypeEncoding: encoding,
            action: action
        )
    }

    private func uuid(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", value)
    }
}
