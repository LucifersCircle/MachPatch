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
            architectureReport: ArchitectureResolver.report(for: inspection.slices)
        )
    }
}

private struct SuccessfulLoader: TargetLoading {
    let target: LoadedTarget

    func loadTarget(at inputURL: URL) async throws -> LoadedTarget {
        target
    }
}

private struct FailingLoader: TargetLoading {
    func loadTarget(at inputURL: URL) async throws -> LoadedTarget {
        throw StubError.failed
    }
}

private enum StubError: Error, LocalizedError {
    case failed

    var errorDescription: String? {
        "The target could not be inspected."
    }
}
