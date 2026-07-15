import Foundation
import MachPatchBuilder
import MachPatchCore
import MachPatchVerifier
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
        guard case .loaded(let analyzedTarget) = model.phase else {
            return XCTFail("Expected an analyzed target")
        }
        XCTAssertEqual(analyzedTarget.patchabilityReport?.summary.classMethodCount, 2)
        XCTAssertEqual(analyzedTarget.patchabilityReport?.summary.patchableClassMethodCount, 2)
        XCTAssertEqual(analyzedTarget.classBrowserTargets.count, 2)
    }

    func testSelectingEmbeddedImageLoadsItAndBindsProjectIdentity() async throws {
        let loadedTarget = makeLoadedTargetWithFramework()
        let frameworkImage = try XCTUnwrap(
            loadedTarget.images.first(where: { $0.image.kind == .dynamicFramework })?.image
        )
        let baseAnalysis = makeAnalysis(for: loadedTarget)
        let frameworkAnalysis = ObjectiveCAnalysis(
            target: loadedTarget.target,
            image: frameworkImage,
            sliceIndex: 0,
            architecture: baseAnalysis.architecture,
            backend: baseAnalysis.backend,
            warnings: [],
            metadata: baseAnalysis.metadata
        )
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget, analysis: frameworkAnalysis)
        )

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        model.selectImage(id: frameworkImage.id)
        await waitForAnalysisToFinish(model)

        XCTAssertEqual(model.analysis?.image, frameworkImage)
        XCTAssertEqual(
            model.currentTargetIdentity?.selectedImage, PatchImageIdentity(image: frameworkImage))
        XCTAssertEqual(
            model.patchProject?.target.selectedImage, PatchImageIdentity(image: frameworkImage))
        XCTAssertEqual(model.patchProject?.projectName, "FixtureKit Patch")
        XCTAssertEqual(model.patchProject?.build.outputName, "FixtureKitPatch")
    }

    func testRevisitingAnalyzedImagesUsesTheInMemoryAnalysisCache() async throws {
        let target = makeLoadedTargetWithFramework()
        let hostAnalysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(hostAnalysis))
        let hostImage = loadedTarget.inspection.image
        let frameworkImage = try XCTUnwrap(
            loadedTarget.images.first(where: { $0.image.kind == .dynamicFramework })?.image
        )
        let frameworkAnalysis = ObjectiveCAnalysis(
            target: loadedTarget.target,
            image: frameworkImage,
            sliceIndex: 0,
            architecture: hostAnalysis.architecture,
            backend: hostAnalysis.backend,
            warnings: [],
            metadata: hostAnalysis.metadata
        )
        let loader = CountingLoader(target: loadedTarget, analysis: frameworkAnalysis)
        let model = WorkspaceModel(loader: loader)

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        model.selectImage(id: frameworkImage.id)
        await waitForAnalysisToFinish(model)
        var analysisLoadCount = await loader.analysisLoadCount
        XCTAssertEqual(analysisLoadCount, 1)

        model.selectImage(id: hostImage.id)
        await waitForAnalysisToFinish(model)
        XCTAssertEqual(model.analysis?.image, hostImage)
        analysisLoadCount = await loader.analysisLoadCount
        XCTAssertEqual(analysisLoadCount, 1)

        model.selectImage(id: frameworkImage.id)
        await waitForAnalysisToFinish(model)
        XCTAssertEqual(model.analysis?.image, frameworkImage)
        analysisLoadCount = await loader.analysisLoadCount
        XCTAssertEqual(analysisLoadCount, 1)
    }

    func testEmbeddedImageArchitectureDoesNotReuseSupportedHostArchitecture() async throws {
        let loadedTarget = makeLoadedTargetWithFramework(frameworkPlatform: .iPhoneSimulator)
        let frameworkImage = try XCTUnwrap(
            loadedTarget.images.first(where: { $0.image.kind == .dynamicFramework })?.image
        )
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        model.selectImage(id: frameworkImage.id)

        guard case .loaded(let selectedTarget) = model.phase else {
            return XCTFail("Expected the target to remain loaded")
        }
        XCTAssertEqual(selectedTarget.inspection.image, frameworkImage)
        XCTAssertTrue(
            selectedTarget.architectureReport.slices.allSatisfy { !$0.supportedForPatching })
        guard case .unavailable = selectedTarget.analysisState else {
            return XCTFail("Expected simulator-only image analysis to be unavailable")
        }
        XCTAssertNil(model.analysis)
        XCTAssertNil(model.patchProject)
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

    func testLargeClassSearchIsIndexedAndReusable() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let classTargets = (0..<3_461).map { classIndex in
            let className = "StressClass\(classIndex)"
            let methods = (0..<13).map { methodIndex in
                ObjectiveCCanonicalMethod(
                    id: "stress-\(classIndex)-\(methodIndex)",
                    className: className,
                    selector:
                        classIndex == 2_000 && methodIndex == 7
                        ? "needleSelector" : "method\(methodIndex)",
                    kind: .instance,
                    typeEncoding: "v16@0:8",
                    implementationAddress: nil,
                    declarations: [],
                    conflictingTypeEncodings: []
                )
            }
            return ObjectiveCClassBrowserTarget(
                id: "stress-class-\(classIndex)",
                name: className,
                superclassName: "NSObject",
                imageName: "StressFixture",
                isLikelyAppDefined: true,
                isObjectiveCVisibleSwift: false,
                isCategoryOnly: false,
                methods: methods,
                properties: [],
                ivars: [],
                protocols: [],
                categoryNames: []
            )
        }
        let loadedTarget = LoadedTarget(
            inputURL: target.inputURL,
            target: target.target,
            inspection: target.inspection,
            architectureReport: target.architectureReport,
            images: target.images,
            iconData: target.iconData,
            analysisState: .loaded(analysis),
            patchabilityReport: nil,
            classBrowserTargets: classTargets
        )
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        model.classSearch = "needleSelector"

        let matchedClass = try XCTUnwrap(model.filteredClasses.first)
        XCTAssertEqual(model.filteredClasses.count, 1)
        XCTAssertEqual(matchedClass.name, "StressClass2000")
        XCTAssertEqual(
            model.methodSearchMatches(for: matchedClass).map(\.selector),
            ["needleSelector"]
        )

        var cachedResultChecksum = 0
        for _ in 0..<100 {
            cachedResultChecksum += model.filteredClasses.count
            cachedResultChecksum += model.methodSearchMatches(for: matchedClass).count
        }
        XCTAssertEqual(cachedResultChecksum, 200)
    }

    func testInspectPatchNavigatesToItsClassAndMethod() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        let patch = try model.addPatch(className: "AppController", method: method)
        model.navigation = .build

        model.inspectPatch(patch)

        XCTAssertEqual(model.navigation, .objectiveCClass("class-app"))
        XCTAssertEqual(model.selectedClass?.name, "AppController")
        XCTAssertEqual(
            model.selectedMethodID,
            ObjectiveCMethodCatalog.identifier(
                className: "AppController",
                kind: .instance,
                selector: "featureEnabled"
            )
        )
        XCTAssertEqual(model.methodRevealRequest?.methodID, model.selectedMethodID)
        XCTAssertNil(model.workspaceAlert)
    }

    func testCategoryOnlyTargetCanBeSearchedPatchedAndNavigated() async throws {
        let target = makeLoadedTarget()
        let baseAnalysis = makeAnalysis(for: target)
        let getter = ObjectiveCMethod(
            id: "category-getter",
            selector: "featureEnabled",
            kind: .instance,
            typeEncoding: "B16@0:8",
            implementationAddress: 0x3000
        )
        let setter = ObjectiveCMethod(
            id: "category-setter",
            selector: "setFeatureEnabled:",
            kind: .instance,
            typeEncoding: "v20@0:8B16",
            implementationAddress: 0x3010
        )
        let category = ObjectiveCCategory(
            id: "category-extras",
            name: "Extras",
            className: "ExternalController",
            instanceMethods: [getter, setter],
            classMethods: [],
            properties: [
                ObjectiveCProperty(
                    id: "category-property",
                    name: "featureEnabled",
                    attributes: "TB,N"
                )
            ],
            protocols: ["FeatureProviding"]
        )
        let analysis = ObjectiveCAnalysis(
            target: baseAnalysis.target,
            sliceIndex: baseAnalysis.sliceIndex,
            architecture: baseAnalysis.architecture,
            backend: baseAnalysis.backend,
            warnings: baseAnalysis.warnings,
            metadata: ObjectiveCMetadata(
                classes: baseAnalysis.metadata.classes,
                protocols: [],
                categories: [category]
            )
        )
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        model.classSearch = "Extras"

        let categoryTarget = try XCTUnwrap(model.filteredClasses.first)
        XCTAssertEqual(categoryTarget.name, "ExternalController")
        XCTAssertTrue(categoryTarget.isCategoryOnly)
        XCTAssertEqual(categoryTarget.categoryNames, ["Extras"])
        XCTAssertEqual(categoryTarget.protocols, ["FeatureProviding"])
        XCTAssertEqual(model.methodSearchMatches(for: categoryTarget).count, 2)
        let property = try XCTUnwrap(categoryTarget.properties.first)
        XCTAssertEqual(property.property.accessorSelectors.getter, "featureEnabled")
        XCTAssertEqual(property.property.accessorSelectors.setter, "setFeatureEnabled:")

        let method = try XCTUnwrap(
            categoryTarget.method(kind: .instance, selector: "featureEnabled")
        )
        let patch = try model.addPatch(className: categoryTarget.name, method: method)
        model.navigation = .build
        model.inspectPatch(patch)

        XCTAssertEqual(model.navigation, .objectiveCClass(categoryTarget.id))
        XCTAssertEqual(model.selectedMethodID, method.id)
        XCTAssertEqual(model.methodRevealRequest?.methodID, method.id)
        XCTAssertNil(model.workspaceAlert)
    }

    func testInspectPatchReportsMissingTargetWithoutLeavingWorkspace() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        model.navigation = .build
        let missingPatch = MethodPatch(
            id: UUID().uuidString,
            enabled: true,
            className: "MissingController",
            selector: "missingMethod",
            methodKind: .instance,
            expectedTypeEncoding: "v16@0:8",
            action: .callOriginal
        )

        model.inspectPatch(missingPatch)

        XCTAssertEqual(model.navigation, .build)
        XCTAssertNil(model.selectedMethodID)
        XCTAssertEqual(model.workspaceAlert?.title, "Patch Target Unavailable")
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

    func testBuildWorkspaceRegeneratesDeterministicSourceFromCanonicalProject() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        guard case .ready(let initialBundle) = model.generatedSourcePreview else {
            return XCTFail("Expected an initial generated source preview")
        }
        let initialSource = try XCTUnwrap(initialBundle.files.first?.contents)
        XCTAssertFalse(initialSource.contains("featureEnabled"))

        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        try model.addPatch(className: "AppController", method: method)

        guard case .ready(let patchedBundle) = model.generatedSourcePreview else {
            return XCTFail("Expected a regenerated source preview")
        }
        let patchedSource = try XCTUnwrap(patchedBundle.files.first?.contents)
        XCTAssertTrue(patchedSource.contains("featureEnabled"))

        model.updateProjectName("Renamed Patch")
        model.updateOutputName("RenamedOutput")
        model.updateMinimumIOSVersion("16.0")
        model.updateARCEnabled(false)

        XCTAssertEqual(model.patchProject?.projectName, "Renamed Patch")
        XCTAssertEqual(model.patchProject?.build.outputName, "RenamedOutput")
        XCTAssertEqual(model.patchProject?.build.minimumIOSVersion, "16.0")
        XCTAssertEqual(model.patchProject?.build.enableARC, false)
        guard case .ready(let regeneratedBundle) = model.generatedSourcePreview else {
            return XCTFail("Expected a valid source preview after settings edits")
        }
        XCTAssertEqual(regeneratedBundle.files.first?.contents, patchedSource)
    }

    func testBuildWorkspaceConstrainsArchitectureAndReportsInvalidSettings() async {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        XCTAssertEqual(model.availableArchitectureModes, [.automatic, .arm64, .universal])
        guard case .resolved(let resolution) = model.architecturePreview else {
            return XCTFail("Expected automatic architecture resolution")
        }
        XCTAssertEqual(resolution.outputArchitecture, .arm64)

        model.updateArchitectureMode(.arm64e)
        XCTAssertEqual(model.projectDraft?.architectureMode, .automatic)

        model.updateOutputName("invalid/name")
        XCTAssertEqual(model.projectValidationReport?.errors.map(\.code), [.invalidOutputName])
        guard case .unavailable = model.generatedSourcePreview else {
            return XCTFail("Invalid settings must suppress generated source")
        }
    }

    func testBuildWorkspaceColumnsRemainWithinAvailableWidth() {
        for availableWidth: CGFloat in [0, 560, 700, 1_000, 1_600] {
            let layout = BuildWorkspaceColumnLayout(availableWidth: availableWidth)

            XCTAssertEqual(layout.totalWidth, max(availableWidth, 1), accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(layout.settingsWidth, 0)
            XCTAssertGreaterThanOrEqual(layout.sourceWidth, 0)
        }

        let wideLayout = BuildWorkspaceColumnLayout(availableWidth: 1_600)
        XCTAssertEqual(wideLayout.settingsWidth, 400)
        XCTAssertEqual(wideLayout.sourceWidth, 1_199)
    }

    func testBuildWorkspaceRightPanelKeepsGeneratedSourceUsable() {
        let compactLayout = BuildWorkspaceRightPanelLayout(availableHeight: 400)
        XCTAssertEqual(compactLayout.generatedSourceHeight, 420)

        let tallLayout = BuildWorkspaceRightPanelLayout(availableHeight: 1_000)
        XCTAssertEqual(tallLayout.generatedSourceHeight, 620)
    }

    func testDylibBuildPublishesArtifactAndProjectEditMarksItStale() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let buildService = StubPatchBuildService()
        let verificationService = StubPatchVerificationService()
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            buildService: buildService,
            verificationService: verificationService
        )
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        model.buildDylib()
        await waitForVerificationToFinish(model)

        guard case .succeeded(let artifact) = model.buildState else {
            return XCTFail("Expected a successful dylib build")
        }
        XCTAssertEqual(artifact.record.architecture, .arm64)
        XCTAssertEqual(artifact.dylibURL.lastPathComponent, "FixturePatch.dylib")
        XCTAssertTrue(model.canExportDylib)
        XCTAssertEqual(model.verificationState.report, verificationService.report)

        model.exportDylib()

        XCTAssertTrue(model.isDylibExporterPresented)
        XCTAssertNotNil(model.dylibExportDocument)
        XCTAssertEqual(model.defaultDylibFilename, "FixturePatch.dylib")
        let dylibExportURL = URL(filePath: "/tmp/FixturePatch.dylib")
        model.handleDylibExport(.success(dylibExportURL))
        XCTAssertEqual(
            model.lastCompletedExport,
            CompletedWorkspaceExport(kind: .dylib, url: dylibExportURL)
        )

        model.updateOutputName("ChangedPatch")

        guard case .stale(let staleArtifact) = model.buildState else {
            return XCTFail("Project edits must mark the successful build stale")
        }
        XCTAssertEqual(staleArtifact, artifact)
        XCTAssertFalse(model.canExportDylib)
        guard case .unavailable = model.verificationState else {
            return XCTFail("A project edit must invalidate the verification report")
        }
    }

    func testDisablingPatchPreservesConfigurationAndOmitsItFromGeneratedSource() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        let createdPatch = try model.addPatch(className: "AppController", method: method)
        let configuredPatch = createdPatch.replacing(action: .returnBoolean(true))
        model.updatePatch(configuredPatch)
        model.updatePatch(configuredPatch.replacing(enabled: false))

        let disabledPatch = try XCTUnwrap(model.patchProject?.patches.first)
        XCTAssertFalse(disabledPatch.enabled)
        XCTAssertEqual(disabledPatch.action, .returnBoolean(true))
        XCTAssertEqual(disabledPatch.id, configuredPatch.id)
        let roundTrippedProject = try PatchProjectCodec.decode(
            PatchProjectCodec.encode(try XCTUnwrap(model.patchProject))
        )
        XCTAssertEqual(roundTrippedProject.patches.first, disabledPatch)
        guard case .ready(let disabledBundle) = model.generatedSourcePreview else {
            return XCTFail("Expected source generation with a disabled patch")
        }
        XCTAssertFalse(disabledBundle.files.first?.contents.contains("featureEnabled") == true)

        model.updatePatch(disabledPatch.replacing(enabled: true))

        guard case .ready(let enabledBundle) = model.generatedSourcePreview else {
            return XCTFail("Expected source regeneration after enabling the patch")
        }
        XCTAssertTrue(enabledBundle.files.first?.contents.contains("featureEnabled") == true)
        XCTAssertTrue(enabledBundle.files.first?.contents.contains("return YES;") == true)
    }

    func testFailedRebuildPreservesArtifactAndStructuredCompilerDiagnostics() async {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let buildService = StubPatchBuildService()
        let verificationService = StubPatchVerificationService()
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            buildService: buildService,
            verificationService: verificationService
        )
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        model.buildDylib()
        await waitForVerificationToFinish(model)
        let successfulArtifact = model.buildState.artifact

        let invocation = BuildCommandInvocation(
            executablePath: "/usr/bin/clang",
            arguments: ["-dynamiclib", "Fixture.m"]
        )
        buildService.failure = .compilerFailed(
            BuildCommandExecution(
                invocation: invocation,
                standardOutput: "",
                standardError: "Fixture.m:12:3: error: synthetic failure\n",
                terminationStatus: 1,
                durationMilliseconds: 9
            )
        )
        model.buildDylib()
        await waitForBuildToFinish(model)

        guard case .failed(let failure, let previousArtifact) = model.buildState else {
            return XCTFail("Expected a failed rebuild")
        }
        XCTAssertEqual(previousArtifact, successfulArtifact)
        XCTAssertEqual(failure.command, "/usr/bin/clang -dynamiclib Fixture.m")
        XCTAssertEqual(failure.terminationStatus, 1)
        XCTAssertEqual(failure.diagnosticText, "Fixture.m:12:3: error: synthetic failure")
    }

    func testBlockingVerificationPreservesBuildAndPreventsExport() async {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let verificationService = StubPatchVerificationService(
            report: makeVerificationReport(status: .failed)
        )
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            buildService: StubPatchBuildService(),
            verificationService: verificationService
        )
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        model.buildDylib()
        await waitForVerificationToFinish(model)

        guard case .succeeded = model.buildState else {
            return XCTFail("A blocked verification must preserve the successful build")
        }
        XCTAssertEqual(model.verificationState.report?.result, .blocked)
        XCTAssertFalse(model.canExportDylib)

        model.exportDylib()

        XCTAssertEqual(model.workspaceAlert?.title, "Verification Required")
        XCTAssertFalse(model.isDylibExporterPresented)
        XCTAssertTrue(model.canExportSourceBundle)
        XCTAssertFalse(model.canExportDebianPackage)
    }

    func testOptionalExportsUseFreshBuildAndExposeExpectedFilenames() async {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            buildService: StubPatchBuildService(),
            verificationService: StubPatchVerificationService()
        )
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        model.buildDylib()
        await waitForVerificationToFinish(model)

        XCTAssertTrue(model.canExportSourceBundle)
        XCTAssertTrue(model.canExportDebianPackage)
        XCTAssertEqual(model.defaultSourceBundleFilename, "FixturePatchSource.zip")
        XCTAssertEqual(model.defaultDebianPackageFilename, "FixturePatch.deb")

        model.exportSourceBundle()

        XCTAssertTrue(model.isSourceBundleExporterPresented)
        XCTAssertNotNil(model.sourceBundleExportDocument)
        let sourceExportURL = URL(filePath: "/tmp/FixturePatchSource.zip")
        model.handleSourceBundleExport(.success(sourceExportURL))
        XCTAssertEqual(
            model.lastCompletedExport,
            CompletedWorkspaceExport(kind: .sourceBundle, url: sourceExportURL)
        )

        model.exportDebianPackage()

        XCTAssertTrue(model.isDebianPackageExporterPresented)
        XCTAssertNotNil(model.debianPackageExportDocument)
        let debianExportURL = URL(filePath: "/tmp/FixturePatch.deb")
        model.handleDebianPackageExport(.success(debianExportURL))
        XCTAssertEqual(
            model.lastCompletedExport,
            CompletedWorkspaceExport(kind: .debianPackage, url: debianExportURL)
        )

        model.updateProjectName("Changed Project")

        XCTAssertFalse(model.canExportSourceBundle)
        XCTAssertFalse(model.canExportDebianPackage)
        XCTAssertFalse(model.isSourceBundleExporterPresented)
        XCTAssertFalse(model.isDebianPackageExporterPresented)
        XCTAssertNil(model.sourceBundleExportDocument)
        XCTAssertNil(model.debianPackageExportDocument)
    }

    func testVerificationExecutionFailureIsVisibleAndPreventsExport() async {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let verificationService = StubPatchVerificationService()
        verificationService.failure = .failed
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            buildService: StubPatchBuildService(),
            verificationService: verificationService
        )
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        model.buildDylib()
        await waitForVerificationToFinish(model)

        guard case .failed(let failure) = model.verificationState else {
            return XCTFail("Expected verification execution failure")
        }
        XCTAssertEqual(failure.message, StubError.failed.localizedDescription)
        XCTAssertNotNil(model.buildState.artifact)
        XCTAssertFalse(model.canExportDylib)
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

        let floatingSignature = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature("d16@0:8")
        XCTAssertEqual(
            PatchActionEditorPolicy.action(
                for: .returnFloatingPoint,
                signature: floatingSignature
            ),
            .returnFloatingPoint(0)
        )

        let classSignature = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature("#16@0:8")
        XCTAssertEqual(
            PatchActionEditorPolicy.action(for: .returnClassNamed, signature: classSignature),
            .returnClassNamed("NSObject")
        )

        let selectorSignature = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature(":16@0:8")
        XCTAssertEqual(
            PatchActionEditorPolicy.action(for: .returnSelector, signature: selectorSignature),
            .returnSelector("description")
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
        model.navigation = .build
        model.exportPatch()
        XCTAssertTrue(model.isProjectExporterPresented)
        model.isProjectExporterPresented = false

        model.openProject(at: projectURL)
        await waitForProjectImport(model)

        XCTAssertEqual(model.patchProject, savedProject)
        XCTAssertEqual(model.navigation, .build)
        XCTAssertNil(model.selectedClass)
    }

    func testPrivatePatchLibrarySavesListsOverwritesAndLoadsWithoutExporter() async throws {
        let libraryURL = FileManager.default.temporaryDirectory.appending(
            path: "MachPatchLibraryTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let library = PatchProjectLibrary(directoryURL: libraryURL)
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            projectLibrary: library
        )

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        try model.addPatch(className: "AppController", method: method)
        let savedProject = try XCTUnwrap(model.patchProject)

        model.savePatch()

        XCTAssertFalse(model.isProjectExporterPresented)
        XCTAssertEqual(model.savedPatchProjects.count, 1)
        let savedEntry = try XCTUnwrap(model.savedPatchProjects.first)
        XCTAssertEqual(savedEntry.projectName, "Fixture Patch")
        XCTAssertEqual(savedEntry.target, savedProject.target)
        XCTAssertEqual(savedEntry.patchCount, 1)
        XCTAssertFalse(savedEntry.fileURL.lastPathComponent.contains(" "))
        XCTAssertEqual(
            try PatchProjectCodec.decode(Data(contentsOf: savedEntry.fileURL)),
            savedProject
        )

        model.savePatch()
        XCTAssertEqual(try library.savedProjects().count, 1)

        model.removePatch(id: try XCTUnwrap(savedProject.patches.first?.id))
        XCTAssertTrue(try XCTUnwrap(model.patchProject).patches.isEmpty)
        model.workspaceAlert = nil

        model.loadPatch(savedEntry)
        XCTAssertEqual(
            model.pendingWorkspaceTransition,
            .openProject(savedEntry.fileURL)
        )
        model.discardAndPerformPendingWorkspaceTransition()
        await waitForProjectImport(model)

        XCTAssertEqual(model.patchProject, savedProject)
        XCTAssertNil(model.pendingProjectImport)
    }

    func testPatchDeletionRequiresConfirmation() async throws {
        let libraryURL = FileManager.default.temporaryDirectory.appending(
            path: "MachPatchDeleteConfirmationTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            projectLibrary: PatchProjectLibrary(directoryURL: libraryURL)
        )
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        let patch = try model.addPatch(className: "AppController", method: method)
        XCTAssertTrue(model.savePatch())
        XCTAssertFalse(model.hasUnsavedPatchChanges)

        model.requestDeletePatch(patch)
        XCTAssertEqual(model.pendingPatchDeletion, patch)
        XCTAssertEqual(model.projectDraft?.patches, [patch])

        model.cancelDeletePatch()
        XCTAssertNil(model.pendingPatchDeletion)
        XCTAssertEqual(model.projectDraft?.patches, [patch])

        model.requestDeletePatch(patch)
        model.confirmDeletePatch()
        XCTAssertNil(model.pendingPatchDeletion)
        XCTAssertTrue(try XCTUnwrap(model.projectDraft?.patches).isEmpty)
        XCTAssertTrue(model.hasUnsavedPatchChanges)
    }

    func testNewPatchPromptsForUnsavedChangesAndCanDiscardThem() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        XCTAssertTrue(model.canStartNewPatch)
        XCTAssertFalse(model.hasUnsavedPatchChanges)

        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        try model.addPatch(className: "AppController", method: method)
        XCTAssertTrue(model.hasUnsavedPatchChanges)

        model.requestNewPatch()
        XCTAssertEqual(model.pendingWorkspaceTransition, .startNewPatch)
        XCTAssertEqual(model.projectDraft?.patches.count, 1)

        model.cancelPendingWorkspaceTransition()
        XCTAssertNil(model.pendingWorkspaceTransition)
        XCTAssertEqual(model.projectDraft?.patches.count, 1)

        model.requestNewPatch()
        model.discardAndPerformPendingWorkspaceTransition()
        XCTAssertNil(model.pendingWorkspaceTransition)
        XCTAssertTrue(try XCTUnwrap(model.projectDraft?.patches).isEmpty)
        XCTAssertFalse(model.hasUnsavedPatchChanges)
    }

    func testNewPatchCanSaveCurrentProjectBeforeResetting() async throws {
        let libraryURL = FileManager.default.temporaryDirectory.appending(
            path: "MachPatchNewProjectTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let library = PatchProjectLibrary(directoryURL: libraryURL)
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            projectLibrary: library
        )
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        try model.addPatch(className: "AppController", method: method)

        model.requestNewPatch()
        model.saveAndPerformPendingWorkspaceTransition()

        XCTAssertNil(model.pendingWorkspaceTransition)
        XCTAssertTrue(try XCTUnwrap(model.projectDraft?.patches).isEmpty)
        XCTAssertFalse(model.hasUnsavedPatchChanges)
        let savedProject = try XCTUnwrap(library.savedProjects().first)
        XCTAssertEqual(savedProject.patchCount, 1)
    }

    func testOpeningTargetCanCancelOrDiscardUnsavedProject() async throws {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        try model.addPatch(className: "AppController", method: method)
        let replacementURL = URL(filePath: "/tmp/Replacement.ipa")

        model.openTarget(at: replacementURL)

        XCTAssertEqual(model.pendingWorkspaceTransition, .openTarget(replacementURL))
        XCTAssertEqual(model.projectDraft?.patches.count, 1)
        model.cancelPendingWorkspaceTransition()
        XCTAssertNil(model.pendingWorkspaceTransition)
        XCTAssertEqual(model.projectDraft?.patches.count, 1)

        model.openTarget(at: replacementURL)
        model.discardAndPerformPendingWorkspaceTransition()
        await waitForLoadToFinish(model)

        XCTAssertNil(model.pendingWorkspaceTransition)
        XCTAssertTrue(try XCTUnwrap(model.projectDraft?.patches).isEmpty)
        XCTAssertFalse(model.hasUnsavedPatchChanges)
    }

    func testLoadingProjectCanSaveCurrentChangesBeforeReplacingThem() async throws {
        let libraryURL = FileManager.default.temporaryDirectory.appending(
            path: "MachPatchTransitionSaveTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let library = PatchProjectLibrary(directoryURL: libraryURL)
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            projectLibrary: library
        )
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let incomingProject = try XCTUnwrap(model.patchProject)
        let projectURL = temporaryProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try PatchProjectCodec.encode(incomingProject).write(to: projectURL)
        let method = try XCTUnwrap(analysis.metadata.classes.first?.instanceMethods.first)
        try model.addPatch(className: "AppController", method: method)

        model.openProject(at: projectURL)

        XCTAssertEqual(model.pendingWorkspaceTransition, .openProject(projectURL))
        XCTAssertEqual(model.projectDraft?.patches.count, 1)
        model.saveAndPerformPendingWorkspaceTransition()
        await waitForPatchProject(model, equalTo: incomingProject)

        XCTAssertNil(model.pendingWorkspaceTransition)
        XCTAssertEqual(model.patchProject, incomingProject)
        XCTAssertFalse(model.hasUnsavedPatchChanges)
        XCTAssertEqual(try XCTUnwrap(library.savedProjects().first).patchCount, 1)
    }

    func testExportedPatchProjectCanConfirmImageSwitchWithoutSavingAgain() async throws {
        let target = makeLoadedTargetWithFramework()
        let hostAnalysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(hostAnalysis))
        let frameworkImage = try XCTUnwrap(
            loadedTarget.images.first(where: { $0.image.kind == .dynamicFramework })?.image
        )
        let frameworkAnalysis = ObjectiveCAnalysis(
            target: loadedTarget.target,
            image: frameworkImage,
            sliceIndex: 0,
            architecture: hostAnalysis.architecture,
            backend: hostAnalysis.backend,
            warnings: [],
            metadata: hostAnalysis.metadata
        )
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget, analysis: frameworkAnalysis)
        )
        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let method = try XCTUnwrap(hostAnalysis.metadata.classes.first?.instanceMethods.first)
        try model.addPatch(className: "AppController", method: method)

        model.selectImage(id: frameworkImage.id)
        XCTAssertEqual(model.pendingWorkspaceTransition, .selectImage(frameworkImage.id))
        model.cancelPendingWorkspaceTransition()

        let patchExportURL = URL(filePath: "/tmp/ExportedPatch.json")
        model.handleProjectExport(.success(patchExportURL))
        XCTAssertFalse(model.hasUnsavedPatchChanges)
        XCTAssertEqual(
            model.lastCompletedExport,
            CompletedWorkspaceExport(kind: .patchProject, url: patchExportURL)
        )
        model.selectImage(id: frameworkImage.id)
        XCTAssertEqual(model.pendingWorkspaceTransition, .selectImage(frameworkImage.id))
        XCTAssertFalse(model.pendingWorkspaceTransitionHasUnsavedChanges)
        XCTAssertEqual(model.projectDraft?.patches.count, 1)
        model.discardAndPerformPendingWorkspaceTransition()
        await waitForAnalysisToFinish(model)

        XCTAssertNil(model.pendingWorkspaceTransition)
        XCTAssertEqual(model.analysis?.image, frameworkImage)
    }

    func testSavedPatchLoadingFiltersByTargetAndDeletionRequiresConfirmation() async throws {
        let libraryURL = FileManager.default.temporaryDirectory.appending(
            path: "MachPatchLibraryFilterTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let library = PatchProjectLibrary(directoryURL: libraryURL)
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(
            loader: SuccessfulLoader(target: loadedTarget),
            projectLibrary: library
        )

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)
        let baseProject = try XCTUnwrap(model.patchProject)
        func project(
            named name: String,
            bundleIdentifier: String?,
            hash: Character,
            cpuSubtype: Int32 = 0
        ) -> PatchProject {
            PatchProject(
                projectName: name,
                target: PatchTargetIdentity(
                    bundleIdentifier: bundleIdentifier,
                    executableName: baseProject.target.executableName,
                    executableSHA256: String(repeating: hash, count: 64),
                    selectedSlice: PatchSelectedSlice(
                        architecture: baseProject.target.selectedSlice.architecture,
                        cpuSubtype: cpuSubtype
                    ),
                    minimumIOSVersion: baseProject.target.minimumIOSVersion
                ),
                build: baseProject.build,
                patches: []
            )
        }

        try library.save(baseProject)
        try library.save(
            project(
                named: "Same App New Build",
                bundleIdentifier: baseProject.target.bundleIdentifier,
                hash: "b"
            )
        )
        try library.save(
            project(
                named: "Other App",
                bundleIdentifier: "com.example.other",
                hash: "c"
            )
        )
        try library.save(
            project(
                named: "Wrong Slice",
                bundleIdentifier: baseProject.target.bundleIdentifier,
                hash: "d",
                cpuSubtype: 2
            )
        )
        model.refreshSavedPatchProjects()

        XCTAssertEqual(model.savedPatchProjects.count, 4)
        XCTAssertEqual(
            Set(model.loadableSavedPatchProjects.map(\.projectName)),
            Set([baseProject.projectName, "Same App New Build"])
        )
        let exact = try XCTUnwrap(
            model.loadableSavedPatchProjects.first { $0.projectName == baseProject.projectName }
        )
        let changed = try XCTUnwrap(
            model.loadableSavedPatchProjects.first { $0.projectName == "Same App New Build" }
        )
        let currentTarget = try XCTUnwrap(model.currentTargetIdentity)
        XCTAssertTrue(exact.isExactExecutableMatch(to: currentTarget))
        XCTAssertFalse(changed.isExactExecutableMatch(to: currentTarget))

        let unrelated = try XCTUnwrap(
            model.savedPatchProjects.first { $0.projectName == "Other App" }
        )
        model.requestDeleteSavedPatch(unrelated)
        XCTAssertEqual(model.pendingSavedPatchDeletion, unrelated)
        model.cancelDeleteSavedPatch()
        XCTAssertNil(model.pendingSavedPatchDeletion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.fileURL.path))

        model.requestDeleteSavedPatch(unrelated)
        model.confirmDeleteSavedPatch()
        XCTAssertNil(model.pendingSavedPatchDeletion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.fileURL.path))
        XCTAssertEqual(model.savedPatchProjects.count, 3)
        XCTAssertEqual(model.workspaceAlert?.title, "Saved Patch Deleted")
    }

    func testSavedPatchWithoutBundleIdentifierRequiresExactExecutableHash() {
        let target = PatchTargetIdentity(
            bundleIdentifier: nil,
            executableName: "DirectBinary",
            executableSHA256: String(repeating: "a", count: 64),
            selectedSlice: PatchSelectedSlice(architecture: .arm64, cpuSubtype: 0),
            minimumIOSVersion: "15.0"
        )
        let saved = SavedPatchProject(
            fileURL: URL(filePath: "/tmp/DirectBinary.json"),
            projectName: "Direct Binary Patch",
            target: target,
            patchCount: 1,
            savedAt: .distantPast
        )
        let changedHash = PatchTargetIdentity(
            bundleIdentifier: nil,
            executableName: target.executableName,
            executableSHA256: String(repeating: "b", count: 64),
            selectedSlice: target.selectedSlice,
            minimumIOSVersion: target.minimumIOSVersion
        )

        XCTAssertTrue(saved.isRelevant(to: target))
        XCTAssertFalse(saved.isRelevant(to: changedHash))
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
                selectedImage: currentProject.target.selectedImage,
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

    private func waitForPatchProject(
        _ model: WorkspaceModel,
        equalTo expectedProject: PatchProject
    ) async {
        for _ in 0..<1_000 {
            if model.patchProject == expectedProject { return }
            await Task.yield()
        }
        XCTFail("Patch project did not finish loading")
    }

    private func waitForBuildToFinish(_ model: WorkspaceModel) async {
        for _ in 0..<1_000 {
            if !model.buildState.isBuilding { return }
            await Task.yield()
        }
        XCTFail("Dylib build did not finish")
    }

    private func waitForVerificationToFinish(_ model: WorkspaceModel) async {
        for _ in 0..<1_000 {
            if !model.buildState.isBuilding {
                switch model.verificationState {
                case .verified, .failed:
                    return
                case .idle, .verifying, .unavailable:
                    break
                }
            }
            await Task.yield()
        }
        XCTFail("Dylib verification did not finish")
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
            analysisState: .requiresSliceSelection,
            patchabilityReport: nil,
            classBrowserTargets: []
        )
    }

    private func makeLoadedTargetWithFramework(
        frameworkPlatform: MachOPlatform = .iPhoneOS
    ) -> LoadedTarget {
        let base = makeLoadedTarget()
        let framework = ResolvedImage(
            id: "dynamicFramework:Frameworks/FixtureKit.framework/FixtureKit",
            kind: .dynamicFramework,
            relativePath: "Frameworks/FixtureKit.framework/FixtureKit",
            bundlePath: "/tmp/Fixture.app/Frameworks/FixtureKit.framework",
            bundleIdentifier: "com.example.fixture-kit",
            displayName: "FixtureKit",
            minimumOSVersion: "15.0",
            supportedPlatforms: ["iPhoneOS"],
            executableName: "FixtureKit",
            executablePath: "/tmp/Fixture.app/Frameworks/FixtureKit.framework/FixtureKit",
            sha256: String(repeating: "b", count: 64)
        )
        let target = ResolvedTarget(
            sourceType: base.target.sourceType,
            sourcePath: base.target.sourcePath,
            bundlePath: base.target.bundlePath,
            bundleIdentifier: base.target.bundleIdentifier,
            displayName: base.target.displayName,
            minimumOSVersion: base.target.minimumOSVersion,
            supportedPlatforms: base.target.supportedPlatforms,
            executableName: base.target.executableName,
            executablePath: base.target.executablePath,
            sha256: base.target.sha256,
            images: [base.target.primaryImage, framework]
        )
        let inspection = MachOInspection(
            target: target,
            image: target.primaryImage,
            slices: base.inspection.slices
        )
        let report = ArchitectureResolver.report(for: inspection.slices)
        let hostSlice = inspection.slices[0]
        let frameworkSlice = MachOSlice(
            index: hostSlice.index,
            architecture: hostSlice.architecture,
            cpuType: hostSlice.cpuType,
            cpuSubtype: hostSlice.cpuSubtype,
            cpuSubtypeBase: hostSlice.cpuSubtypeBase,
            cpuSubtypeCapabilities: hostSlice.cpuSubtypeCapabilities,
            fileType: .dynamicLibrary,
            fileTypeValue: 6,
            endianness: hostSlice.endianness,
            is64Bit: hostSlice.is64Bit,
            platform: frameworkPlatform,
            platformValue: frameworkPlatform == .iPhoneOS ? 2 : 7,
            minimumOSVersion: hostSlice.minimumOSVersion,
            sdkVersion: hostSlice.sdkVersion,
            encrypted: hostSlice.encrypted,
            encryptionCryptID: hostSlice.encryptionCryptID,
            encryptionOffset: hostSlice.encryptionOffset,
            encryptionSize: hostSlice.encryptionSize,
            fileOffset: hostSlice.fileOffset,
            fileSize: hostSlice.fileSize,
            installName: "@rpath/FixtureKit.framework/FixtureKit",
            linkedLibraries: hostSlice.linkedLibraries
        )
        let frameworkReport = ArchitectureResolver.report(for: [frameworkSlice])
        return LoadedTarget(
            inputURL: base.inputURL,
            target: target,
            inspection: inspection,
            architectureReport: report,
            images: [
                LoadedTargetImage(
                    image: target.primaryImage,
                    inspectionState: .available(
                        slices: inspection.slices,
                        architectureReport: report
                    )
                ),
                LoadedTargetImage(
                    image: framework,
                    inspectionState: .available(
                        slices: [frameworkSlice],
                        architectureReport: frameworkReport
                    )
                ),
            ],
            iconData: base.iconData,
            analysisState: .requiresSliceSelection,
            patchabilityReport: nil,
            classBrowserTargets: []
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
        expectedHostSHA256: String,
        imageID: String,
        expectedImageSHA256: String,
        sliceIndex: Int
    ) async throws -> LoadedObjectiveCAnalysis {
        guard let analysis else { throw StubError.failed }
        return LoadedObjectiveCAnalysis(
            analysis: analysis,
            patchabilityReport: ObjectiveCPatchabilityAnalyzer.report(for: analysis.metadata),
            classBrowserTargets: ObjectiveCClassBrowserCatalog.targets(for: analysis)
        )
    }
}

private actor CountingLoader: TargetLoading {
    let target: LoadedTarget
    let analysis: ObjectiveCAnalysis
    private(set) var analysisLoadCount = 0

    init(target: LoadedTarget, analysis: ObjectiveCAnalysis) {
        self.target = target
        self.analysis = analysis
    }

    func loadTarget(at inputURL: URL) async throws -> LoadedTarget {
        target
    }

    func loadAnalysis(
        at inputURL: URL,
        expectedHostSHA256: String,
        imageID: String,
        expectedImageSHA256: String,
        sliceIndex: Int
    ) async throws -> LoadedObjectiveCAnalysis {
        analysisLoadCount += 1
        return LoadedObjectiveCAnalysis(
            analysis: analysis,
            patchabilityReport: ObjectiveCPatchabilityAnalyzer.report(for: analysis.metadata),
            classBrowserTargets: ObjectiveCClassBrowserCatalog.targets(for: analysis)
        )
    }
}

private final class StubPatchBuildService: PatchBuildServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: PatchDylibBuilderError?
    private let artifact: PatchBuildArtifact

    init() {
        artifact = StubPatchBuildService.makeArtifact()
    }

    var failure: PatchDylibBuilderError? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    func build(
        project: PatchProject,
        progress: @escaping @Sendable (PatchBuildProgress) -> Void
    ) throws -> PatchBuildArtifact {
        progress(
            PatchBuildProgress(
                phase: .compiling,
                architecture: .arm64,
                completedUnitCount: 3,
                totalUnitCount: 5,
                message: "Compiling the arm64 dylib slice…"
            )
        )
        if let failure = lock.withLock({ storedFailure }) { throw failure }
        progress(
            PatchBuildProgress(
                phase: .completed,
                completedUnitCount: 5,
                totalUnitCount: 5,
                message: "Dylib build completed."
            )
        )
        return artifact
    }

    private static func makeArtifact() -> PatchBuildArtifact {
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "MachPatchAppTestBuild-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let resolution = BuildArchitectureResolution(
            requestedMode: .automatic,
            outputArchitecture: .arm64,
            slices: [.arm64],
            targetArchitecture: .arm64,
            targetCPUSubtype: 0,
            targetArm64eABI: nil,
            reason: "Test resolution"
        )
        let toolchain = AppleToolchain(
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            xcodeVersion: "Xcode 26.0",
            clangPath: "/usr/bin/clang",
            clangVersion: "Apple clang 17.0",
            lipoPath: "/usr/bin/lipo",
            nmPath: "/usr/bin/nm",
            sdkPath: "/Applications/Xcode.app/iPhoneOS.sdk",
            sdkVersion: "26.0"
        )
        let record = PatchBuildRecord(
            projectName: "Fixture Patch",
            architecture: .arm64,
            minimumIOSVersion: "15.0",
            installName: "@rpath/FixturePatch.dylib",
            sourcePath: workspace.appending(path: "MachPatchGenerated.m").path,
            outputPath: workspace.appending(path: "FixturePatch.dylib").path,
            recordPath: workspace.appending(path: "MachPatchBuild.json").path,
            toolchain: toolchain,
            architectureResolution: resolution,
            capabilityProbes: [],
            slices: [],
            symbolChecks: [],
            merge: nil
        )
        try? FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        try? Data("test dylib".utf8).write(to: URL(filePath: record.outputPath))
        try? Data("// test generated source\n".utf8).write(to: URL(filePath: record.sourcePath))
        return PatchBuildArtifact(workspaceURL: workspace, record: record)
    }
}

private final class StubPatchVerificationService: PatchVerificationServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReport: DylibVerificationReport
    private var storedFailure: StubError?

    init(report: DylibVerificationReport = makeVerificationReport(status: .passed)) {
        storedReport = report
    }

    var report: DylibVerificationReport {
        lock.withLock { storedReport }
    }

    var failure: StubError? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    func verify(
        artifact _: PatchBuildArtifact,
        targetInspection _: MachOInspection
    ) throws -> DylibVerificationReport {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            return storedReport
        }
    }
}

private func makeVerificationReport(status: VerificationCheckStatus) -> DylibVerificationReport {
    DylibVerificationReport(
        dylibPath: "/tmp/FixturePatch.dylib",
        target: nil,
        slices: [],
        targetSlices: [],
        lipoArchitectures: ["arm64"],
        dependencies: [],
        unresolvedSymbols: [],
        forbiddenPaths: [],
        checks: [
            VerificationCheck(
                code: .targetCompatibility,
                status: status,
                message: status == .failed
                    ? "The generated dylib does not match the selected target."
                    : "The generated dylib matches the selected target."
            )
        ],
        toolExecutions: []
    )
}

private struct FailingLoader: TargetLoading {
    func loadTarget(at inputURL: URL) async throws -> LoadedTarget {
        throw StubError.failed
    }

    func loadAnalysis(
        at inputURL: URL,
        expectedHostSHA256: String,
        imageID: String,
        expectedImageSHA256: String,
        sliceIndex: Int
    ) async throws -> LoadedObjectiveCAnalysis {
        throw StubError.failed
    }
}

private enum StubError: Error, LocalizedError {
    case failed

    var errorDescription: String? {
        "The target could not be inspected."
    }
}
