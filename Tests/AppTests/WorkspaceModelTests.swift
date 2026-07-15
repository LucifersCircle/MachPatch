import Foundation
import MachPatchBuilder
import MachPatchCore
import XCTest

@testable import MachPatchApp

@MainActor
final class WorkspaceModelTests: XCTestCase {
    func testImporterAndDropStateAreExplicit() {
        let model = WorkspaceModel(loader: SuccessfulLoader(target: makeLoadedTarget()))

        XCTAssertEqual(model.phase, .empty)
        XCTAssertFalse(model.isImporterPresented)
        XCTAssertFalse(model.isDropTargeted)

        model.chooseTarget()
        model.setDropTargeted(true)

        XCTAssertTrue(model.isImporterPresented)
        XCTAssertTrue(model.isDropTargeted)
    }

    func testSuccessfulLoadPublishesResolvedTarget() async {
        let loadedTarget = makeLoadedTarget()
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        XCTAssertEqual(model.phase, .loaded(loadedTarget))
    }

    func testFailedLoadPreservesInputAndDiagnostic() async {
        let inputURL = URL(filePath: "/tmp/Unsupported.txt")
        let model = WorkspaceModel(loader: FailingLoader())

        model.openTarget(at: inputURL)
        await waitForLoadToFinish(model)

        XCTAssertEqual(
            model.phase,
            .failed(
                WorkspaceFailure(
                    inputURL: inputURL,
                    message: StubError.failed.localizedDescription
                )
            )
        )
    }

    func testExplicitArchitectureSelectionLoadsAnalysis() async {
        let loadedTarget = makeLoadedTarget()
        let analysis = makeAnalysis(for: loadedTarget)
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget, analysis: analysis)
        )

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        model.selectArchitecture(sliceIndex: 0)
        await waitForAnalysisToFinish(model)

        XCTAssertEqual(model.analysis, analysis)
    }

    func testClassFiltersSearchMethodsAndSelection() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        XCTAssertEqual(model.classFilter, .all)
        XCTAssertEqual(model.filteredClasses.map(\.name), ["AppController", "SDKClass"])

        model.classFilter = .likelyAppDefined
        XCTAssertEqual(model.filteredClasses.map(\.name), ["AppController"])

        model.classFilter = .all
        model.classSearch = "sdkMethod"
        XCTAssertEqual(model.filteredClasses.map(\.name), ["SDKClass"])
        let methodMatchedClass = try XCTUnwrap(model.filteredClasses.first)
        XCTAssertEqual(
            model.methodSearchMatches(for: methodMatchedClass).map(\.selector),
            ["sdkMethod"]
        )

        model.classSearch = "SDKClass"
        XCTAssertEqual(model.filteredClasses.map(\.name), ["SDKClass"])
        let classNameMatchedClass = try XCTUnwrap(model.filteredClasses.first)
        XCTAssertTrue(model.methodSearchMatches(for: classNameMatchedClass).isEmpty)

        model.navigation = .objectiveCClass("class-sdk")
        XCTAssertEqual(model.selectedClass?.name, "SDKClass")
    }

    func testClassBrowserColumnsRemainWithinAvailableWidth() {
        for availableWidth: CGFloat in [560, 640, 800, 1_600] {
            let layout = ClassBrowserColumnLayout(availableWidth: availableWidth)

            XCTAssertEqual(layout.totalWidth, availableWidth, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(layout.metadataWidth, 0)
            XCTAssertGreaterThanOrEqual(layout.methodWidth, 0)
            XCTAssertGreaterThanOrEqual(layout.inspectorWidth, 0)
        }

        let wideLayout = ClassBrowserColumnLayout(availableWidth: 1_600)
        XCTAssertEqual(wideLayout.metadataWidth, 260)
        XCTAssertEqual(wideLayout.inspectorWidth, 340)
    }

    func testPatchDraftRecordsTargetSliceAndCreatesCanonicalPatch() throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        var draft = try XCTUnwrap(PatchProjectDraft(loadedTarget: loadedTarget))
        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        let patchID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))

        let patch = try draft.addPatch(
            className: "AppController",
            method: method,
            id: patchID
        )

        XCTAssertEqual(draft.projectName, "Fixture Patch")
        XCTAssertEqual(draft.outputName, "FixturePatch")
        XCTAssertEqual(draft.target.executableSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(
            draft.target.selectedSlice, PatchSelectedSlice(architecture: .arm64, cpuSubtype: 0))
        XCTAssertEqual(patch.id, patchID.uuidString)
        XCTAssertEqual(patch.expectedTypeEncoding, "B16@0:8")
        XCTAssertEqual(patch.action, .callOriginal)
        XCTAssertTrue(draft.validationReport.isValid)
    }

    func testPatchActionPolicyIsTypeAwareAndExplainsUnsupportedSignatures() throws {
        let booleanSignature = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature("B16@0:8")

        XCTAssertEqual(
            PatchActionEditorPolicy.action(for: .returnBoolean, signature: booleanSignature),
            .returnBoolean(false)
        )
        XCTAssertNil(
            PatchActionEditorPolicy.action(for: .returnString, signature: booleanSignature))
        XCTAssertEqual(
            PatchActionEditorPolicy.unavailableReason(
                for: .returnString,
                signature: booleanSignature
            ),
            "Requires an Objective-C object return; this method returns boolean."
        )

        let unsupportedSignature = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature(
            "{Pair=ii}16@0:8"
        )
        XCTAssertEqual(
            PatchActionEditorPolicy.unavailableReason(
                for: .callOriginal,
                signature: unsupportedSignature
            ),
            "The complete method signature contains an unsupported ABI type."
        )
    }

    func testPatchDraftRejectsMethodWithoutTypeEncoding() throws {
        let target = makeLoadedTarget()
        let loadedTarget = target.replacingAnalysisState(.loaded(makeAnalysis(for: target)))
        var draft = try XCTUnwrap(PatchProjectDraft(loadedTarget: loadedTarget))
        let method = ObjectiveCMethod(
            id: "missing-encoding",
            selector: "unknown",
            kind: .instance,
            typeEncoding: nil,
            implementationAddress: nil
        )

        XCTAssertThrowsError(try draft.addPatch(className: "AppController", method: method)) {
            XCTAssertEqual($0 as? PatchDraftError, .typeEncodingUnavailable)
        }
    }

    func testSelectingAnalyzedSliceDoesNotDiscardPatchDraft() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        try model.addPatch(className: "AppController", method: method)

        model.selectArchitecture(sliceIndex: 0)

        XCTAssertEqual(model.projectDraft?.patches.count, 1)
        XCTAssertEqual(model.projectDraft?.patches.first?.selector, "featureEnabled")
    }

    func testProjectSaveAndOpenRoundTripAgainstCachedAnalysis() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        try model.addPatch(className: "AppController", method: method)
        let savedProject = try XCTUnwrap(model.patchProject)
        let projectURL = temporaryProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try PatchProjectCodec.encode(savedProject).write(to: projectURL)

        model.removePatch(id: try XCTUnwrap(savedProject.patches.first?.id))
        model.saveProject()
        XCTAssertTrue(model.isProjectExporterPresented)
        model.isProjectExporterPresented = false

        model.openProject(at: projectURL)
        await waitForProjectImport(model)

        XCTAssertEqual(model.patchProject, savedProject)
        XCTAssertEqual(model.selectedClass?.name, "AppController")
    }

    func testChangedTargetProjectRequiresExplicitRetargetDecision() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let currentProject = try XCTUnwrap(model.patchProject)
        let changedProject = PatchProject(
            projectName: currentProject.projectName,
            target: PatchTargetIdentity(
                bundleIdentifier: currentProject.target.bundleIdentifier,
                executableName: currentProject.target.executableName,
                executableSHA256: String(repeating: "b", count: 64),
                selectedSlice: currentProject.target.selectedSlice,
                minimumIOSVersion: currentProject.target.minimumIOSVersion
            ),
            build: currentProject.build,
            patches: currentProject.patches
        )
        let projectURL = temporaryProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try PatchProjectCodec.encode(changedProject).write(to: projectURL)

        model.openProject(at: projectURL)
        await waitForProjectImport(model)

        XCTAssertEqual(model.pendingProjectImport?.project, changedProject)
        XCTAssertEqual(model.pendingProjectImport?.warnings.map(\.code), [.targetHashMismatch])

        model.resolvePendingProjectImport(retarget: true)

        XCTAssertEqual(
            model.patchProject?.target.executableSHA256, String(repeating: "a", count: 64))
        XCTAssertNil(model.pendingProjectImport)
    }

    func testTargetIconLoaderUsesTheDeclaredBundleIcon() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appending(path: "MachPatchIcon-\(UUID().uuidString).app", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": ["PrimaryIcon"]
                ]
            ]
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: bundleURL.appending(path: "Info.plist"))
        let iconData = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        try iconData.write(to: bundleURL.appending(path: "PrimaryIcon@2x.png"))
        try Data(repeating: 0xFF, count: 512).write(
            to: bundleURL.appending(path: "UnrelatedIcon.png")
        )
        let target = ResolvedTarget(
            sourceType: .applicationBundle,
            sourcePath: bundleURL.path,
            bundlePath: bundleURL.path,
            bundleIdentifier: "com.example.icon",
            displayName: "Icon Fixture",
            minimumOSVersion: "15.0",
            supportedPlatforms: ["iPhoneOS"],
            executableName: "IconFixture",
            executablePath: bundleURL.appending(path: "IconFixture").path,
            sha256: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(TargetIconLoader().loadIconData(for: target), iconData)
    }

    private func waitForLoadToFinish(_ model: WorkspaceModel) async {
        for _ in 0..<100 {
            if case .loading = model.phase {
                await Task.yield()
            } else {
                return
            }
        }
        XCTFail("Workspace load did not finish")
    }

    private func waitForAnalysisToFinish(_ model: WorkspaceModel) async {
        for _ in 0..<100 {
            if case .loaded(let target) = model.phase,
                case .loading = target.analysisState
            {
                await Task.yield()
            } else {
                return
            }
        }
        XCTFail("Objective-C analysis did not finish")
    }

    private func waitForProjectImport(_ model: WorkspaceModel) async {
        for _ in 0..<1_000 {
            if model.pendingProjectImport != nil || model.workspaceAlert != nil
                || model.patchProject?.patches.isEmpty == false
            {
                return
            }
            await Task.yield()
        }
        XCTFail("Patch project import did not finish")
    }

    private func temporaryProjectURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MachPatch-\(UUID().uuidString).json")
    }

    private func makeLoadedTarget() -> LoadedTarget {
        let inputURL = URL(filePath: "/tmp/Fixture.ipa")
        let resolvedTarget = ResolvedTarget(
            sourceType: .ipa,
            sourcePath: inputURL.path,
            bundlePath: "/tmp/Fixture.app",
            bundleIdentifier: "com.example.fixture",
            displayName: "Fixture",
            minimumOSVersion: "15.0",
            supportedPlatforms: ["iPhoneOS"],
            executableName: "Fixture",
            executablePath: "/tmp/Fixture.app/Fixture",
            sha256: String(repeating: "a", count: 64)
        )
        let slice = MachOSlice(
            index: 0,
            architecture: .arm64,
            cpuType: 0x0100_000C,
            cpuSubtype: 0,
            cpuSubtypeBase: 0,
            cpuSubtypeCapabilities: 0,
            fileType: .executable,
            fileTypeValue: 2,
            endianness: .little,
            is64Bit: true,
            platform: .iPhoneOS,
            platformValue: 2,
            minimumOSVersion: "15.0",
            sdkVersion: "17.0",
            encrypted: false,
            encryptionCryptID: 0,
            encryptionOffset: 0,
            encryptionSize: 0,
            fileOffset: 0,
            fileSize: 4_096,
            installName: nil,
            linkedLibraries: []
        )
        let inspection = MachOInspection(target: resolvedTarget, slices: [slice])
        return LoadedTarget(
            inputURL: inputURL,
            target: resolvedTarget,
            inspection: inspection,
            architectureReport: ArchitectureResolver.report(for: inspection.slices),
            iconData: nil,
            analysisState: .requiresSliceSelection
        )
    }

    private func makeAnalysis(for target: LoadedTarget) -> ObjectiveCAnalysis {
        ObjectiveCAnalysis(
            target: target.target,
            sliceIndex: 0,
            architecture: .arm64,
            backend: .otool,
            warnings: [],
            metadata: ObjectiveCMetadata(
                classes: [
                    ObjectiveCClass(
                        id: "class-app",
                        name: "AppController",
                        superclassName: "NSObject",
                        imageName: "Fixture",
                        isLikelyAppDefined: true,
                        isObjectiveCVisibleSwift: false,
                        instanceMethods: [
                            ObjectiveCMethod(
                                id: "method-app",
                                selector: "featureEnabled",
                                kind: .instance,
                                typeEncoding: "B16@0:8",
                                implementationAddress: 0x1000
                            )
                        ],
                        classMethods: [],
                        properties: [],
                        ivars: [],
                        protocols: []
                    ),
                    ObjectiveCClass(
                        id: "class-sdk",
                        name: "SDKClass",
                        superclassName: "NSObject",
                        imageName: "Fixture",
                        isLikelyAppDefined: false,
                        isObjectiveCVisibleSwift: false,
                        instanceMethods: [
                            ObjectiveCMethod(
                                id: "method-sdk",
                                selector: "sdkMethod",
                                kind: .instance,
                                typeEncoding: "v16@0:8",
                                implementationAddress: nil
                            )
                        ],
                        classMethods: [],
                        properties: [],
                        ivars: [],
                        protocols: []
                    ),
                ],
                protocols: [],
                categories: []
            )
        )
    }
}

private struct SuccessfulLoader: TargetLoading {
    let target: LoadedTarget
    var analysis: ObjectiveCAnalysis?

    init(target: LoadedTarget, analysis: ObjectiveCAnalysis? = nil) {
        self.target = target
        self.analysis = analysis
    }

    func loadTarget(at inputURL: URL) async throws -> LoadedTarget {
        target
    }

    func loadAnalysis(
        at inputURL: URL,
        expectedSHA256: String,
        sliceIndex: Int
    ) async throws -> ObjectiveCAnalysis {
        guard let analysis else { throw StubError.failed }
        return analysis
    }
}

private struct FailingLoader: TargetLoading {
    func loadTarget(at inputURL: URL) async throws -> LoadedTarget {
        throw StubError.failed
    }

    func loadAnalysis(
        at inputURL: URL,
        expectedSHA256: String,
        sliceIndex: Int
    ) async throws -> ObjectiveCAnalysis {
        throw StubError.failed
    }
}

private enum StubError: Error, LocalizedError {
    case failed

    var errorDescription: String? {
        "The target could not be inspected."
    }
}
