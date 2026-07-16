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
        XCTAssertTrue(
            source.contains(
                "Logging destination: target-process NSLog, default severity, [MachPatch] prefix."
            )
        )
        XCTAssertTrue(source.contains("#import <objc/runtime.h>"))
        XCTAssertTrue(
            source.contains("static BOOL MPPatch_0_FixtureManager_featureEnabled_Replacement"))
        XCTAssertTrue(source.contains("return YES;"))
        XCTAssertTrue(source.contains("return (long long)-42LL;"))
        XCTAssertTrue(source.contains("return (unsigned long long)42ULL;"))
        XCTAssertTrue(source.contains("static float MPPatch_13_FixtureManager_opacity_Replacement"))
        XCTAssertTrue(source.contains("return 0x1.4p+0f;"))
        XCTAssertTrue(source.contains("return nil;"))
        XCTAssertTrue(source.contains("return objc_getClass(\"NSString\");"))
        XCTAssertTrue(source.contains("return sel_registerName(\"description\");"))
        XCTAssertTrue(source.contains("return NULL;"))
        XCTAssertTrue(source.contains("return @\"Fixture\";"))
        XCTAssertTrue(source.contains("return @[@\"one\", @\"two\"];"))
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

    func testGeneratesComposableAdvancedBehaviorDeterministically() throws {
        let patch = makePatch(
            index: 20,
            selector: "featureFor:object:",
            encoding: "B32@0:8B16@24",
            action: .callOriginal,
            advanced: PatchAdvancedConfiguration(
                argumentReplacements: [
                    PatchArgumentReplacement(argumentIndex: 0, value: .boolean(true)),
                    PatchArgumentReplacement(argumentIndex: 1, value: .string("changed")),
                ],
                beforeEffects: [
                    .showAlert(
                        PatchAlert(title: "MachPatch", message: "Called", buttonTitle: "Dismiss")
                    ),
                    .customObjectiveC(PatchCustomObjectiveC(source: "NSLog(@\"before\");")),
                ],
                afterEffects: [
                    .customObjectiveC(
                        PatchCustomObjectiveC(
                            source: "NSLog(@\"after = %d\", (int)originalResult);"
                        )
                    )
                ],
                conditionalReturn: PatchConditionalReturn(
                    condition: PatchCondition(
                        source: .invocationCount,
                        comparison: .greaterThan,
                        value: .unsignedInteger(3)
                    ),
                    replacement: .boolean(false)
                ),
                invocationCounter: PatchInvocationCounter(logEachInvocation: false)
            )
        )

        let first = try generate(makeProject(patches: [patch]))
        let second = try generate(makeProject(patches: [patch]))

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("#import <UIKit/UIKit.h>"))
        XCTAssertTrue(first.contains("static void MPShowAlert"))
        XCTAssertTrue(
            first.contains(
                "Suppressed alert because another alert is already visible."
            )
        )
        XCTAssertTrue(first.contains("__atomic_add_fetch"))
        XCTAssertTrue(first.contains("if (invocationCount > (unsigned long long)3ULL)"))
        XCTAssertTrue(first.contains("MPShowAlert(@\"MachPatch\", @\"Called\", @\"Dismiss\")"))
        XCTAssertTrue(first.contains("argument0 = YES;"))
        XCTAssertTrue(first.contains("argument1 = @\"changed\";"))
        XCTAssertTrue(first.contains("NSLog(@\"before\");"))
        XCTAssertTrue(first.contains("NSLog(@\"after = %d\", (int)originalResult);"))
    }

    func testGeneratesAtomicRuntimeControlBypassAndTypedValues() throws {
        let boolean = makePatch(
            index: 60,
            selector: "featureEnabled",
            action: .returnBoolean(false),
            advanced: PatchAdvancedConfiguration(
                beforeEffects: [
                    .customObjectiveC(PatchCustomObjectiveC(source: "NSLog(@\"patched\");"))
                ],
                invocationCounter: PatchInvocationCounter(logEachInvocation: false)
            ),
            runtimeControl: PatchRuntimeControlConfiguration(
                title: "Feature Enabled",
                defaultEnabled: false,
                order: 0,
                value: .boolean(true)
            )
        )
        let signed = makePatch(
            index: 61,
            selector: "signedValue",
            encoding: "c@:",
            action: .returnSignedInteger(1),
            runtimeControl: PatchRuntimeControlConfiguration(
                title: "Signed Value",
                order: 1,
                value: .signedInteger(
                    PatchRuntimeSignedIntegerConfiguration(defaultValue: -7)
                )
            )
        )
        let unsigned = makePatch(
            index: 62,
            selector: "unsignedValue",
            encoding: "C@:",
            action: .callOriginalAndReplace(.unsignedInteger(1)),
            runtimeControl: PatchRuntimeControlConfiguration(
                title: "Unsigned Value",
                order: 2,
                value: .unsignedInteger(
                    PatchRuntimeUnsignedIntegerConfiguration(defaultValue: 9)
                )
            )
        )
        let source = try generate(
            makeProject(
                runtimeControls: PatchRuntimeControlsConfiguration(
                    id: uuid(100),
                    activationMode: .both
                ),
                patches: [boolean, signed, unsigned]
            )
        )

        XCTAssertTrue(source.contains("#import <UIKit/UIKit.h>"))
        XCTAssertTrue(source.contains("static BOOL MPRuntimeControlsMasterEnabled = YES;"))
        XCTAssertTrue(
            source.contains(
                "static BOOL MPPatch_0_FixtureManager_featureEnabled_ControlEnabled = NO;")
        )
        XCTAssertTrue(
            source.contains(
                "static BOOL MPPatch_0_FixtureManager_featureEnabled_ControlValue = YES;")
        )
        XCTAssertTrue(
            source.contains(
                "static int64_t MPPatch_1_FixtureManager_signedValue_ControlValue = -7LL;")
        )
        XCTAssertTrue(
            source.contains(
                "static uint64_t MPPatch_2_FixtureManager_unsignedValue_ControlValue = 9ULL;")
        )
        XCTAssertTrue(
            source.contains(
                "BOOL runtimeControlEnabled = __atomic_load_n(&MPRuntimeControlsMasterEnabled"
            )
        )
        XCTAssertTrue(source.contains("if (!runtimeControlEnabled)"))
        XCTAssertTrue(source.contains("return MPPatch_0_FixtureManager_featureEnabled_Original"))
        XCTAssertTrue(source.contains("BOOL runtimeControlValue = __atomic_load_n"))
        XCTAssertTrue(source.contains("return runtimeControlValue;"))
        XCTAssertTrue(source.contains("return (signed char)runtimeControlValue;"))
        XCTAssertTrue(source.contains("return (unsigned char)runtimeControlValue;"))
        XCTAssertFalse(source.contains("BOOL persistent;"))
        XCTAssertTrue(source.contains("MPLoadPersistedRuntimeControls();"))
        XCTAssertTrue(source.contains("MPRuntimeControlPersistenceKey(descriptor, @\"enabled\")"))
        XCTAssertTrue(source.contains("static const BOOL MPConfiguredShowsButton = YES;"))
        XCTAssertTrue(source.contains("static const BOOL MPConfiguredInstallsGesture = YES;"))
        XCTAssertTrue(source.contains("gesture.minimumPressDuration = 3.0;"))
        XCTAssertTrue(source.contains("gestureRecognizer.numberOfTouches == 3"))
        XCTAssertTrue(source.contains("gesture.cancelsTouchesInView = NO;"))
        XCTAssertTrue(source.contains("if (UIAccessibilityIsVoiceOverRunning())"))
        XCTAssertTrue(source.contains("self.buttonHiddenForSession = NO;"))
        XCTAssertTrue(source.contains("self.buttonPanGesture.enabled = !forceAccessibleButton;"))
        XCTAssertTrue(source.contains("[window removeGestureRecognizer:self.activationGesture]"))
        XCTAssertTrue(source.contains("button.alpha = 0.28;"))
        XCTAssertTrue(source.contains("CGRectGetMaxX(window.bounds)"))

        let bypass = try XCTUnwrap(source.range(of: "if (!runtimeControlEnabled)"))
        let counter = try XCTUnwrap(source.range(of: "__atomic_add_fetch"))
        let effect = try XCTUnwrap(source.range(of: "NSLog(@\"patched\")"))
        XCTAssertLessThan(bypass.lowerBound, counter.lowerBound)
        XCTAssertLessThan(bypass.lowerBound, effect.lowerBound)
    }

    func testRuntimeControlsSourceLinksDeviceDylibWithWarningsAsErrors() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("xcrun is unavailable")
        }
        let patch = makePatch(
            index: 70,
            selector: "featureEnabled",
            action: .returnBoolean(true),
            runtimeControl: PatchRuntimeControlConfiguration(
                title: "Feature Enabled",
                order: 0,
                value: .boolean(false)
            )
        )
        let project = makeProject(
            runtimeControls: PatchRuntimeControlsConfiguration(
                id: uuid(101),
                activationMode: .both
            ),
            patches: [patch]
        )
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-RuntimeControlsCompile-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundle = try ObjectiveCSourceGenerator().generate(project)
        let sourceURL = try XCTUnwrap(GeneratedSourceWriter.write(bundle, to: workspace).first)
        let dylibURL = workspace.appending(path: "RuntimeControls.dylib")

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = [
            "--sdk", "iphoneos", "clang",
            "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
            "-dynamiclib", "-arch", "arm64", "-miphoneos-version-min=15.0",
            "-framework", "Foundation", "-framework", "UIKit",
            "-framework", "CoreGraphics",
            "-Wl,-install_name,@rpath/RuntimeControls.dylib",
            "-x", "objective-c", sourceURL.path, "-o", dylibURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dylibURL.path), diagnostics)
    }

    func testGeneratesFloatingPointClassAndSelectorFamilies() throws {
        let floating = makePatch(
            index: 30,
            selector: "adjust:",
            encoding: "d24@0:8f16",
            action: .callOriginalAndReplace(.floatingPoint(4.5)),
            advanced: PatchAdvancedConfiguration(
                argumentReplacements: [
                    PatchArgumentReplacement(argumentIndex: 0, value: .floatingPoint(2.5))
                ],
                conditionalReturn: PatchConditionalReturn(
                    condition: PatchCondition(
                        source: .argument(0),
                        comparison: .greaterThan,
                        value: .floatingPoint(1.5)
                    ),
                    replacement: .floatingPoint(3.5)
                )
            )
        )
        let loggedFloat = makePatch(
            index: 31,
            selector: "scaled:",
            encoding: "f24@0:8f16",
            action: .logArguments
        )
        let source = try generate(
            makeProject(
                patches: [floating, loggedFloat] + scalarClassAndSelectorPatches()
            )
        )

        XCTAssertTrue(
            source.contains("double (*MPPatch_0_FixtureManager_adjust_Function)(id, SEL, float)"))
        XCTAssertTrue(source.contains("if (argument0 > 0x1.8p+0f)"))
        XCTAssertTrue(source.contains("return 0x1.cp+1;"))
        XCTAssertTrue(source.contains("argument0 = 0x1.4p+1f;"))
        XCTAssertTrue(source.contains("return 0x1.2p+2;"))
        XCTAssertTrue(source.contains("argument 1 = %.9g"))
        XCTAssertTrue(source.contains("returned %.17g"))
        XCTAssertTrue(source.contains("objc_getClass(\"NSString\")"))
        XCTAssertTrue(source.contains("sel_registerName(\"description\")"))
        XCTAssertTrue(source.contains("return NULL;"))
        XCTAssertTrue(source.contains("NSStringFromSelector(originalResult)"))
        XCTAssertTrue(source.contains("argument0 == NULL"))
        XCTAssertTrue(source.contains("argument0 = NULL;"))
    }

    func testSafeScalarFamiliesPassDeviceClangWarningsAsErrors() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("xcrun is unavailable")
        }
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-ScalarCompile-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundle = try ObjectiveCSourceGenerator().generate(
            makeProject(patches: scalarClassAndSelectorPatches())
        )
        let sourceURL = try XCTUnwrap(GeneratedSourceWriter.write(bundle, to: workspace).first)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = [
            "--sdk", "iphoneos", "clang",
            "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
            "-fsyntax-only", "-arch", "arm64", "-miphoneos-version-min=15.0",
            "-x", "objective-c", sourceURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
    }

    func testComplexABITiersGenerateSafeTypedSourceAndPassDeviceClang() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("xcrun is unavailable")
        }
        let patches = [
            makePatch(
                index: 60,
                selector: "runWithPointer:block:",
                encoding: "v32@0:8^v16@?24",
                action: .logArguments,
                advanced: PatchAdvancedConfiguration(
                    argumentReplacements: [
                        PatchArgumentReplacement(argumentIndex: 0, value: .nilValue),
                        PatchArgumentReplacement(argumentIndex: 1, value: .nilValue),
                    ]
                )
            ),
            makePatch(
                index: 61,
                selector: "usePoint:",
                encoding: "v32@0:8{CGPoint=dd}16",
                action: .logArguments
            ),
            makePatch(
                index: 62,
                selector: "size",
                encoding: "{CGSize=dd}16@0:8",
                action: .logOriginalReturnValue
            ),
            makePatch(
                index: 63,
                selector: "transformRect:",
                encoding:
                    "{CGRect={CGPoint=dd}{CGSize=dd}}48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16",
                action: .logOriginalReturnValue
            ),
            makePatch(
                index: 64,
                selector: "range",
                encoding: "{_NSRange=QQ}16@0:8",
                action: .logOriginalReturnValue
            ),
        ]
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-ComplexABICompile-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundle = try ObjectiveCSourceGenerator().generate(makeProject(patches: patches))
        let source = try XCTUnwrap(bundle.files.first?.contents)
        let sourceURL = try XCTUnwrap(GeneratedSourceWriter.write(bundle, to: workspace).first)

        XCTAssertTrue(source.contains("#import <CoreGraphics/CoreGraphics.h>"))
        XCTAssertTrue(source.contains("void *, id"))
        XCTAssertTrue(source.contains("argument0 = NULL;"))
        XCTAssertTrue(source.contains("argument1 = nil;"))
        XCTAssertTrue(source.contains("block address = %p"))
        XCTAssertTrue(source.contains("pointer = %p"))
        XCTAssertTrue(source.contains("CGPoint { x = %.17g, y = %.17g }"))
        XCTAssertTrue(source.contains("CGSize { width = %.17g, height = %.17g }"))
        XCTAssertTrue(source.contains("CGRect { x = %.17g, y = %.17g"))
        XCTAssertTrue(source.contains("NSRange { location = %llu, length = %llu }"))

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = [
            "--sdk", "iphoneos", "clang",
            "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
            "-fsyntax-only", "-arch", "arm64", "-miphoneos-version-min=15.0",
            "-x", "objective-c", sourceURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
    }

    func testAdvancedUIKitSourcePassesDeviceClangWarningsAsErrors() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("xcrun is unavailable")
        }
        let patch = makePatch(
            index: 21,
            selector: "setEnabled:",
            encoding: "v24@0:8B16",
            action: .callOriginal,
            advanced: PatchAdvancedConfiguration(
                argumentReplacements: [
                    PatchArgumentReplacement(argumentIndex: 0, value: .boolean(true))
                ],
                beforeEffects: [
                    .showAlert(PatchAlert(title: "MachPatch", message: "Enabled")),
                    .customObjectiveC(PatchCustomObjectiveC(source: "(void)self;")),
                ],
                afterEffects: [
                    .customObjectiveC(PatchCustomObjectiveC(source: "(void)_cmd;"))
                ],
                invocationCounter: PatchInvocationCounter(logEachInvocation: false)
            )
        )
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-AdvancedCompile-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundle = try ObjectiveCSourceGenerator().generate(makeProject(patches: [patch]))
        let sourceURL = try XCTUnwrap(GeneratedSourceWriter.write(bundle, to: workspace).first)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = [
            "--sdk", "iphoneos", "clang",
            "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
            "-fsyntax-only", "-arch", "arm64", "-miphoneos-version-min=15.0",
            "-x", "objective-c", sourceURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
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
            selector: "a:b:c:d:e:f:g:h:i:j:k:l:m:n:o:p:",
            encoding: "v@:BcCsSiIlLqQ@#:fd",
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
            "float argument14",
            "double argument15",
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
                        index: 30,
                        selector: "a:b:c:d:e:f:g:h:i:j:k:l:m:n:o:p:",
                        encoding: "v@:BcCsSiIlLqQ@#:fd",
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
            makePatch(
                index: 12,
                selector: "items",
                encoding: "@@:",
                action: .returnObject(.arrayOfStrings(["one", "two"]))
            ),
            makePatch(
                index: 13,
                selector: "opacity",
                encoding: "f@:",
                action: .returnFloatingPoint(1.25)
            ),
            makePatch(
                index: 14,
                selector: "modelClass",
                encoding: "#@:",
                action: .returnClassNamed("NSString")
            ),
            makePatch(
                index: 15,
                selector: "callbackSelector",
                encoding: ":@:",
                action: .returnSelector("description")
            ),
            makePatch(
                index: 16,
                selector: "optionalSelector",
                encoding: ":@:",
                action: .returnNil
            ),
        ]
    }

    private func scalarClassAndSelectorPatches() -> [MethodPatch] {
        [
            makePatch(
                index: 40,
                selector: "scale:",
                encoding: "d24@0:8f16",
                action: .logOriginalReturnValue,
                advanced: PatchAdvancedConfiguration(
                    argumentReplacements: [
                        PatchArgumentReplacement(argumentIndex: 0, value: .floatingPoint(2.5))
                    ],
                    beforeEffects: [
                        .customObjectiveC(PatchCustomObjectiveC(source: "(void)argument0;"))
                    ],
                    afterEffects: [
                        .customObjectiveC(
                            PatchCustomObjectiveC(
                                source: "NSLog(@\"scaled = %.17g\", originalResult);"
                            )
                        )
                    ],
                    conditionalReturn: PatchConditionalReturn(
                        condition: PatchCondition(
                            source: .argument(0),
                            comparison: .greaterThan,
                            value: .floatingPoint(10.5)
                        ),
                        replacement: .floatingPoint(10.5)
                    )
                )
            ),
            makePatch(
                index: 41,
                selector: "modelClass",
                encoding: "#@:",
                action: .returnClassNamed("NSString")
            ),
            makePatch(
                index: 42,
                selector: "callbackSelector",
                encoding: ":@:",
                action: .returnSelector("description")
            ),
            makePatch(
                index: 43,
                selector: "optionalSelector",
                encoding: ":@:",
                action: .returnNil
            ),
            makePatch(
                index: 44,
                selector: "replacementSelector",
                encoding: ":@:",
                action: .callOriginalAndReplace(.selector("length"))
            ),
            makePatch(
                index: 45,
                selector: "loggedSelector",
                encoding: ":@:",
                action: .logOriginalReturnValue
            ),
            makePatch(
                index: 46,
                selector: "selectorFor:",
                encoding: ":24@0:8:16",
                action: .callOriginalAndReplace(.selector("length")),
                advanced: PatchAdvancedConfiguration(
                    argumentReplacements: [
                        PatchArgumentReplacement(argumentIndex: 0, value: .nilValue)
                    ],
                    conditionalReturn: PatchConditionalReturn(
                        condition: PatchCondition(
                            source: .argument(0),
                            comparison: .equal,
                            value: .nilValue
                        ),
                        replacement: .selector("description")
                    )
                )
            ),
            makePatch(
                index: 47,
                selector: "leastFloat",
                encoding: "f@:",
                action: .returnFloatingPoint(Double(Float.leastNonzeroMagnitude))
            ),
            makePatch(
                index: 48,
                selector: "greatestFloat",
                encoding: "f@:",
                action: .returnFloatingPoint(Double(Float.greatestFiniteMagnitude))
            ),
            makePatch(
                index: 49,
                selector: "leastDouble",
                encoding: "d@:",
                action: .returnFloatingPoint(Double.leastNonzeroMagnitude)
            ),
            makePatch(
                index: 50,
                selector: "greatestDouble",
                encoding: "d@:",
                action: .returnFloatingPoint(Double.greatestFiniteMagnitude)
            ),
        ]
    }

    private func makeProject(
        runtimeControls: PatchRuntimeControlsConfiguration? = nil,
        patches: [MethodPatch]? = nil
    ) -> PatchProject {
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
            runtimeControls: runtimeControls,
            patches: patches ?? [makePatch(index: 0)]
        )
    }

    private func makePatch(
        index: Int,
        className: String = "FixtureManager",
        selector: String? = nil,
        methodKind: ObjectiveCMethodKind = .instance,
        encoding: String = "B@:",
        action: PatchAction = .returnBoolean(true),
        advanced: PatchAdvancedConfiguration? = nil,
        runtimeControl: PatchRuntimeControlConfiguration? = nil
    ) -> MethodPatch {
        MethodPatch(
            id: uuid(index + 1),
            enabled: true,
            className: className,
            selector: selector ?? "method\(index)",
            methodKind: methodKind,
            expectedTypeEncoding: encoding,
            action: action,
            advanced: advanced,
            runtimeControl: runtimeControl
        )
    }

    private func uuid(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", value)
    }
}
