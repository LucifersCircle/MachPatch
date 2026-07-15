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

    func testClassFiltersSearchMethodsAndSelection() async {
        let target = makeLoadedTarget()
        let analysis = makeAnalysis(for: target)
        let loadedTarget = target.replacingAnalysisState(.loaded(analysis))
        let model = WorkspaceModel(loader: SuccessfulLoader(target: loadedTarget))

        model.openTarget(at: loadedTarget.inputURL)
        await waitForLoadToFinish(model)

        XCTAssertEqual(model.filteredClasses.map(\.name), ["AppController"])

        model.classFilter = .all
        model.classSearch = "sdkMethod"
        XCTAssertEqual(model.filteredClasses.map(\.name), ["SDKClass"])

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
