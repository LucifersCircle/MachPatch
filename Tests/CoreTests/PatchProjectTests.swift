import Foundation
import MachPatchCore
import XCTest

final class PatchProjectTests: XCTestCase {
    func testProjectJSONRoundTripIsDeterministicAndPreservesActionShape() throws {
        let project = makeProject(action: .returnBoolean(true))

        let firstEncoding = try PatchProjectCodec.encode(project)
        let decoded = try PatchProjectCodec.decode(firstEncoding)
        let secondEncoding = try PatchProjectCodec.encode(decoded)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(firstEncoding, secondEncoding)
        XCTAssertEqual(firstEncoding.last, 0x0A)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstEncoding) as? [String: Any]
        )
        let patches = try XCTUnwrap(object["patches"] as? [[String: Any]])
        let action = try XCTUnwrap(patches.first?["action"] as? [String: Any])
        XCTAssertEqual(action["kind"] as? String, "returnBoolean")
        XCTAssertEqual(action["value"] as? Bool, true)
    }

    func testRepositoryExampleIsAValidVersionOneProject() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appending(path: "Examples/ExamplePatch.json"))
        let project = try PatchProjectCodec.decode(data)

        XCTAssertEqual(project.formatVersion, 1)
        XCTAssertTrue(PatchProjectValidator.validate(project).isValid)
    }

    func testEveryPatchActionRoundTrips() throws {
        let actions: [PatchAction] = [
            .returnBoolean(false),
            .returnSignedInteger(-42),
            .returnUnsignedInteger(42),
            .returnNil,
            .returnString("Fixture"),
            .logInvocation,
            .logArguments,
            .logOriginalReturnValue,
            .callOriginal,
            .callOriginalAndReplace(.boolean(true)),
            .callOriginalAndReplace(.signedInteger(-1)),
            .callOriginalAndReplace(.unsignedInteger(1)),
            .callOriginalAndReplace(.nilValue),
            .callOriginalAndReplace(.string("Replacement")),
        ]

        for action in actions {
            let project = makeProject(action: action)
            XCTAssertEqual(try PatchProjectCodec.decode(PatchProjectCodec.encode(project)), project)
        }
    }

    func testCodecRejectsUnsupportedVersionsAndOversizedInput() throws {
        let unsupported = makeProject(formatVersion: 2)
        XCTAssertThrowsError(try PatchProjectCodec.encode(unsupported)) { error in
            XCTAssertEqual(error as? PatchProjectCodecError, .unsupportedFormatVersion(2))
        }

        let rawUnsupported = try JSONEncoder().encode(unsupported)
        XCTAssertThrowsError(try PatchProjectCodec.decode(rawUnsupported)) { error in
            XCTAssertEqual(error as? PatchProjectCodecError, .unsupportedFormatVersion(2))
        }

        let oversized = Data(count: PatchProjectCodec.maximumProjectBytes + 1)
        XCTAssertThrowsError(try PatchProjectCodec.decode(oversized)) { error in
            XCTAssertEqual(
                error as? PatchProjectCodecError,
                .projectTooLarge(PatchProjectCodec.maximumProjectBytes + 1)
            )
        }
    }

    func testValidBooleanProjectPassesStructuralAndActionValidation() {
        let report = PatchProjectValidator.validate(makeProject(action: .returnBoolean(true)))
        XCTAssertTrue(report.isValid)
        XCTAssertTrue(report.errors.isEmpty)
    }

    func testRejectsIncompatibleActionsAndUnsupportedABITypes() {
        let voidBoolean = validate(action: .returnBoolean(true), encoding: "v@:")
        XCTAssertTrue(voidBoolean.errors.contains { $0.code == .incompatibleAction })

        let structure = validate(action: .callOriginal, encoding: "{Point=dd}@:")
        XCTAssertTrue(structure.errors.contains { $0.code == .unsupportedReturnType })

        let block = validate(action: .logInvocation, encoding: "v24@0:8@?16", selector: "run:")
        XCTAssertTrue(block.errors.contains { $0.code == .unsupportedArgumentType })
        XCTAssertTrue(block.errors.contains { $0.code == .incompatibleAction })
    }

    func testLegacyCharIsAnIntegerUnlessBooleanIsExplicitlySupportedLater() {
        XCTAssertTrue(
            validate(action: .returnBoolean(true), encoding: "c@:").errors.contains {
                $0.code == .incompatibleAction
            }
        )
        XCTAssertTrue(validate(action: .returnSignedInteger(1), encoding: "c@:").isValid)
    }

    func testRejectsIntegerValuesOutsideEncodedWidth() {
        XCTAssertTrue(
            validate(action: .returnSignedInteger(128), encoding: "c@:").errors.contains {
                $0.code == .incompatibleAction
            }
        )
        XCTAssertTrue(validate(action: .returnSignedInteger(-128), encoding: "c@:").isValid)
        XCTAssertTrue(
            validate(action: .returnUnsignedInteger(256), encoding: "C@:").errors.contains {
                $0.code == .incompatibleAction
            }
        )
        XCTAssertTrue(validate(action: .returnUnsignedInteger(255), encoding: "C@:").isValid)
    }

    func testValidatesSelectorArityAndImplicitMethodArguments() {
        let arity = validate(action: .callOriginal, encoding: "v24@0:8i16")
        XCTAssertTrue(arity.errors.contains { $0.code == .invalidSelector })

        let missingImplicitArguments = validate(action: .returnBoolean(true), encoding: "B")
        XCTAssertTrue(
            missingImplicitArguments.errors.contains { $0.code == .invalidMethodSignature }
        )
    }

    func testObjectAndClassReturnActionsAreDistinct() throws {
        let object = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature("@@:")
        XCTAssertTrue(PatchActionCompatibility.allowedActions(for: object).contains(.returnString))
        XCTAssertNil(
            PatchActionCompatibility.incompatibility(action: .returnNil, signature: object)
        )

        let classObject = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature("#@:")
        XCTAssertFalse(
            PatchActionCompatibility.allowedActions(for: classObject).contains(.returnString)
        )
        XCTAssertNotNil(
            PatchActionCompatibility.incompatibility(
                action: .callOriginalAndReplace(.string("Wrong")),
                signature: classObject
            )
        )
    }

    func testReportsDuplicateIDsTargetsAndMalformedIdentity() {
        let first = makePatch(id: "not-a-uuid")
        let second = makePatch(id: "not-a-uuid")
        let project = makeProject(
            executableSHA256: "short",
            outputName: "bad/name",
            patches: [first, second]
        )

        let report = PatchProjectValidator.validate(project)
        XCTAssertTrue(report.errors.contains { $0.code == .invalidExecutableSHA256 })
        XCTAssertTrue(report.errors.contains { $0.code == .invalidOutputName })
        XCTAssertTrue(report.errors.contains { $0.code == .invalidPatchID })
        XCTAssertTrue(report.errors.contains { $0.code == .duplicatePatchID })
        XCTAssertTrue(report.errors.contains { $0.code == .duplicatePatchTarget })
    }

    func testRejectsRuntimeNamesWithWhitespaceOrControlCharacters() {
        let invalidClass = MethodPatch(
            id: "4F154FAA-1E35-44AA-B014-30EAE65C3F47",
            enabled: true,
            className: "Bad Class",
            selector: "featureEnabled",
            methodKind: .instance,
            expectedTypeEncoding: "B@:",
            action: .returnBoolean(true)
        )
        let invalidSelector = MethodPatch(
            id: "C415D294-6669-428F-9044-75B1BD91CB20",
            enabled: true,
            className: "FixtureManager",
            selector: "bad\u{0000}selector",
            methodKind: .instance,
            expectedTypeEncoding: "B@:",
            action: .returnBoolean(true)
        )
        let report = PatchProjectValidator.validate(
            makeProject(patches: [invalidClass, invalidSelector])
        )

        XCTAssertTrue(report.errors.contains { $0.code == .invalidClassName })
        XCTAssertTrue(report.errors.contains { $0.code == .invalidSelector })
    }

    private func validate(
        action: PatchAction,
        encoding: String,
        selector: String = "featureEnabled"
    ) -> PatchProjectValidationReport {
        PatchProjectValidator.validate(
            makeProject(
                patches: [makePatch(selector: selector, encoding: encoding, action: action)]
            )
        )
    }

    private func makeProject(
        formatVersion: Int = PatchProject.currentFormatVersion,
        executableSHA256: String = String(repeating: "a", count: 64),
        outputName: String = "ExamplePatch",
        action: PatchAction = .returnBoolean(true),
        patches: [MethodPatch]? = nil
    ) -> PatchProject {
        PatchProject(
            formatVersion: formatVersion,
            projectName: "Example Patch",
            target: PatchTargetIdentity(
                bundleIdentifier: "com.example.fixture",
                executableName: "Fixture",
                executableSHA256: executableSHA256,
                selectedSlice: PatchSelectedSlice(architecture: .arm64, cpuSubtype: 0),
                minimumIOSVersion: "15.0"
            ),
            build: PatchBuildConfiguration(
                architectureMode: .automatic,
                minimumIOSVersion: "15.0",
                outputName: outputName,
                enableARC: true
            ),
            patches: patches ?? [makePatch(action: action)]
        )
    }

    private func makePatch(
        id: String = "4F154FAA-1E35-44AA-B014-30EAE65C3F47",
        selector: String = "featureEnabled",
        encoding: String = "B@:",
        action: PatchAction = .returnBoolean(true)
    ) -> MethodPatch {
        MethodPatch(
            id: id,
            enabled: true,
            className: "FixtureManager",
            selector: selector,
            methodKind: .instance,
            expectedTypeEncoding: encoding,
            action: action
        )
    }
}
