import Foundation
import MachPatchCore
import XCTest

@testable import MachPatchAnalyzer

final class AnalyzedPatchProjectValidatorTests: XCTestCase {
    func testValidatesClassSelectorKindAndEncodingAgainstAnalysis() throws {
        let fixture = try FixtureAnalysis()
        defer { fixture.remove() }

        let report = try AnalyzedPatchProjectValidator.validate(
            makeProject(),
            against: fixture.analysis
        )

        XCTAssertTrue(report.isValid)
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testDetectsWrongMethodKind() throws {
        let fixture = try FixtureAnalysis()
        defer { fixture.remove() }

        let report = try AnalyzedPatchProjectValidator.validate(
            makeProject(methodKind: .class),
            against: fixture.analysis
        )

        XCTAssertTrue(report.errors.contains { $0.code == .methodKindMismatch })
    }

    func testDetectsMissingClassAndSelector() throws {
        let fixture = try FixtureAnalysis()
        defer { fixture.remove() }

        let missingClass = try AnalyzedPatchProjectValidator.validate(
            makeProject(className: "MissingClass"),
            against: fixture.analysis
        )
        XCTAssertTrue(missingClass.errors.contains { $0.code == .classNotFound })

        let missingSelector = try AnalyzedPatchProjectValidator.validate(
            makeProject(selector: "missingSelector"),
            against: fixture.analysis
        )
        XCTAssertTrue(missingSelector.errors.contains { $0.code == .methodNotFound })
    }

    func testDetectsChangedTypeEncoding() throws {
        let fixture = try FixtureAnalysis()
        defer { fixture.remove() }

        let report = try AnalyzedPatchProjectValidator.validate(
            makeProject(encoding: "B@:"),
            against: fixture.analysis
        )

        XCTAssertTrue(report.errors.contains { $0.code == .typeEncodingChanged })
    }

    func testSeparatesRetargetingWarningsFromSliceErrors() throws {
        let fixture = try FixtureAnalysis()
        defer { fixture.remove() }
        let project = makeProject(
            executableName: "OldFixture",
            executableSHA256: String(repeating: "c", count: 64),
            bundleIdentifier: "com.example.old",
            architecture: .x8664,
            cpuSubtype: 2
        )

        let report = try AnalyzedPatchProjectValidator.validate(
            project,
            against: fixture.analysis
        )

        XCTAssertTrue(report.warnings.contains { $0.code == .targetHashMismatch })
        XCTAssertTrue(report.warnings.contains { $0.code == .targetExecutableNameMismatch })
        XCTAssertTrue(report.warnings.contains { $0.code == .targetBundleIdentifierMismatch })
        XCTAssertTrue(report.errors.contains { $0.code == .targetArchitectureMismatch })
        XCTAssertTrue(report.errors.contains { $0.code == .targetCPUSubtypeMismatch })
    }

    func testSelectsTheExactArchitectureAndSubtypeFromFatBinary() throws {
        let arm64 = MachOFixtureFactory.thin64(cpuSubtype: 0, cryptID: 0)
        let arm64e = MachOFixtureFactory.thin64(cpuSubtype: 2, cryptID: 0)
        let fat = MachOFixtureFactory.fat32(slices: [
            (MachOFixtureFactory.cpuTypeARM64, 0, arm64),
            (MachOFixtureFactory.cpuTypeARM64, 2, arm64e),
        ])
        let url = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-PatchSliceFixture-\(UUID().uuidString)"
        )
        try fat.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = ResolvedTarget(
            sourceType: .machO,
            sourcePath: url.path,
            bundlePath: nil,
            bundleIdentifier: nil,
            displayName: nil,
            minimumOSVersion: nil,
            supportedPlatforms: [],
            executableName: "Fixture",
            executablePath: url.path,
            sha256: FixtureAnalysis.sha256
        )

        XCTAssertEqual(
            try AnalyzedPatchProjectValidator.selectedSliceIndex(
                for: makeProject(architecture: .arm64e, cpuSubtype: 2),
                in: target
            ),
            1
        )
        XCTAssertThrowsError(
            try AnalyzedPatchProjectValidator.selectedSliceIndex(
                for: makeProject(architecture: .x8664, cpuSubtype: 3),
                in: target
            )
        ) { error in
            XCTAssertEqual(
                error as? AnalyzedPatchProjectValidationError,
                .selectedSliceNotFound(.x8664, 3)
            )
        }
    }

    private func makeProject(
        executableName: String = "Fixture",
        executableSHA256: String = FixtureAnalysis.sha256,
        bundleIdentifier: String = "com.example.fixture",
        architecture: MachOArchitecture = .arm64,
        cpuSubtype: Int32 = 0,
        className: String = "FixtureManager",
        selector: String = "featureEnabled",
        methodKind: ObjectiveCMethodKind = .instance,
        encoding: String = "B16@0:8"
    ) -> PatchProject {
        PatchProject(
            projectName: "Fixture Patch",
            target: PatchTargetIdentity(
                bundleIdentifier: bundleIdentifier,
                executableName: executableName,
                executableSHA256: executableSHA256,
                selectedSlice: PatchSelectedSlice(
                    architecture: architecture,
                    cpuSubtype: cpuSubtype
                ),
                minimumIOSVersion: "15.0"
            ),
            build: PatchBuildConfiguration(
                architectureMode: .automatic,
                minimumIOSVersion: "15.0",
                outputName: "FixturePatch",
                enableARC: true
            ),
            patches: [
                MethodPatch(
                    id: "4F154FAA-1E35-44AA-B014-30EAE65C3F47",
                    enabled: true,
                    className: className,
                    selector: selector,
                    methodKind: methodKind,
                    expectedTypeEncoding: encoding,
                    action: .returnBoolean(true)
                )
            ]
        )
    }
}

private struct FixtureAnalysis {
    static let sha256 = String(repeating: "b", count: 64)

    let analysis: ObjectiveCAnalysis

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "MachPatch-PatchValidatorFixture-\(UUID().uuidString)"
        )
        try MachOFixtureFactory.thin64(cryptID: 0).write(to: url)
        let target = ResolvedTarget(
            sourceType: .machO,
            sourcePath: url.path,
            bundlePath: nil,
            bundleIdentifier: "com.example.fixture",
            displayName: "Fixture",
            minimumOSVersion: "15.0",
            supportedPlatforms: ["iPhoneOS"],
            executableName: "Fixture",
            executablePath: url.path,
            sha256: Self.sha256
        )
        let method = ObjectiveCMethod(
            id: "method:class:FixtureManager:instance:featureEnabled",
            selector: "featureEnabled",
            kind: .instance,
            typeEncoding: "B16@0:8",
            implementationAddress: 0x1000
        )
        let objectiveCClass = ObjectiveCClass(
            id: "class:FixtureManager",
            name: "FixtureManager",
            superclassName: "NSObject",
            imageName: "Fixture",
            isLikelyAppDefined: true,
            isObjectiveCVisibleSwift: false,
            instanceMethods: [method],
            classMethods: [],
            properties: [],
            ivars: [],
            protocols: []
        )
        analysis = ObjectiveCAnalysis(
            target: target,
            sliceIndex: 0,
            architecture: .arm64,
            backend: .otool,
            warnings: [],
            metadata: ObjectiveCMetadata(
                classes: [objectiveCClass],
                protocols: [],
                categories: []
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: analysis.target.executableURL)
    }
}
