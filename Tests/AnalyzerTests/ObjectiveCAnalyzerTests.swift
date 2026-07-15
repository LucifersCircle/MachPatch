import Foundation
import MachPatchCore
import XCTest

@testable import MachPatchAnalyzer

final class ObjectiveCAnalyzerTests: XCTestCase {
    func testFallsBackToAvailableProviderAndPreservesWarning() throws {
        let fixture = try FixtureTarget(data: MachOFixtureFactory.thin64(cryptID: 0))
        defer { fixture.remove() }

        let metadata = RawObjectiveCMetadata(
            classes: [
                RawObjectiveCClass(
                    name: "FixtureController",
                    superclassName: "UIViewController",
                    instanceMethods: [
                        RawObjectiveCMethod(
                            selector: "enabled",
                            kind: .instance,
                            typeEncoding: "B@:",
                            implementationAddress: 0x1234
                        )
                    ]
                )
            ]
        )
        let analyzer = ObjectiveCAnalyzer(providers: [
            UnavailableProvider(reason: "test dependency is absent"),
            StaticProvider(metadata: metadata),
        ])

        let analysis = try analyzer.analyze(fixture.target)

        XCTAssertEqual(analysis.backend, .otool)
        XCTAssertEqual(
            analysis.warnings,
            ["liefExtended unavailable: test dependency is absent"]
        )
        XCTAssertEqual(analysis.architecture, .arm64)
        XCTAssertEqual(analysis.metadata.classes.map(\.name), ["FixtureController"])
        XCTAssertEqual(
            analysis.metadata.classes[0].instanceMethods.map(\.selector),
            ["enabled"]
        )
        XCTAssertEqual(analysis.metadata.classes[0].instanceMethods[0].typeEncoding, "B@:")
    }

    func testReportsEveryProviderFailure() throws {
        let fixture = try FixtureTarget(data: MachOFixtureFactory.thin64(cryptID: 0))
        defer { fixture.remove() }
        let analyzer = ObjectiveCAnalyzer(providers: [
            UnavailableProvider(reason: "missing"),
            ThrowingProvider(),
        ])

        XCTAssertThrowsError(try analyzer.analyze(fixture.target)) { error in
            guard case .allProvidersFailed(let reasons) = error as? ObjectiveCAnalyzerError else {
                return XCTFail("Expected allProvidersFailed, received \(error)")
            }
            XCTAssertEqual(reasons.count, 2)
            XCTAssertEqual(reasons[0], "liefExtended unavailable: missing")
            XCTAssertTrue(reasons[1].hasPrefix("otool failed:"))
        }
    }

    func testRejectsEncryptedSliceBeforeMetadataExtraction() throws {
        let fixture = try FixtureTarget(data: MachOFixtureFactory.thin64(cryptID: 1))
        defer { fixture.remove() }
        let analyzer = ObjectiveCAnalyzer(providers: [StaticProvider(metadata: .init())])

        XCTAssertThrowsError(try analyzer.analyze(fixture.target)) { error in
            XCTAssertEqual(error as? ObjectiveCAnalyzerError, .encryptedSlice(0, 1))
        }
    }

    func testRejectsMissingSliceIndex() throws {
        let fixture = try FixtureTarget(data: MachOFixtureFactory.thin64(cryptID: 0))
        defer { fixture.remove() }
        let analyzer = ObjectiveCAnalyzer(providers: [StaticProvider(metadata: .init())])

        XCTAssertThrowsError(try analyzer.analyze(fixture.target, sliceIndex: 1)) { error in
            XCTAssertEqual(error as? ObjectiveCAnalyzerError, .sliceIndexOutOfRange(1))
        }
    }
}

private struct UnavailableProvider: ObjectiveCMetadataProvider {
    let backend = ObjectiveCAnalyzerBackend.liefExtended
    let reason: String

    func availability() -> ProviderAvailability { .unavailable(reason) }

    func extractMetadata(
        from executableURL: URL,
        slice: MachOSlice
    ) throws -> RawObjectiveCMetadata {
        XCTFail("An unavailable provider must not be called")
        return .init()
    }
}

private struct StaticProvider: ObjectiveCMetadataProvider {
    let backend = ObjectiveCAnalyzerBackend.otool
    let metadata: RawObjectiveCMetadata

    func availability() -> ProviderAvailability { .available }

    func extractMetadata(
        from executableURL: URL,
        slice: MachOSlice
    ) throws -> RawObjectiveCMetadata {
        metadata
    }
}

private struct ThrowingProvider: ObjectiveCMetadataProvider {
    let backend = ObjectiveCAnalyzerBackend.otool

    func availability() -> ProviderAvailability { .available }

    func extractMetadata(
        from executableURL: URL,
        slice: MachOSlice
    ) throws -> RawObjectiveCMetadata {
        throw TestProviderError.failed
    }
}

private enum TestProviderError: Error {
    case failed
}

private struct FixtureTarget {
    let target: ResolvedTarget

    init(data: Data) throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-ObjectiveCAnalyzerFixture-\(UUID().uuidString)"
        )
        try data.write(to: url)
        target = ResolvedTarget(
            sourceType: .machO,
            sourcePath: url.path,
            bundlePath: nil,
            bundleIdentifier: nil,
            displayName: nil,
            minimumOSVersion: nil,
            supportedPlatforms: [],
            executableName: "Fixture",
            executablePath: url.path,
            sha256: "fixture"
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: target.executableURL)
    }
}
