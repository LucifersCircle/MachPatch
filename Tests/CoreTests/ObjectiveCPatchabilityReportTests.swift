import Foundation
import MachPatchCore
import XCTest

final class ObjectiveCPatchabilityReportTests: XCTestCase {
    func testClassifiesSupportedAndUnavailableMethodDeclarations() throws {
        let metadata = ObjectiveCMetadata(
            classes: [
                makeClass(
                    name: "FixtureController",
                    methods: [
                        makeMethod("supported", encoding: "B16@0:8"),
                        makeMethod("missing", encoding: nil),
                        makeMethod("invalid", encoding: "x"),
                        makeMethod("badImplicit", encoding: "B16#0:8"),
                        makeMethod("takesValue:", encoding: "v16@0:8"),
                        makeMethod("floatingResult", encoding: "d16@0:8"),
                        makeMethod("takesFloating:", encoding: "v24@0:8d16"),
                        makeMethod("structureResult", encoding: "{Point=dd}16@0:8"),
                        makeMethod("takesStructure:", encoding: "v32@0:8{Point=dd}16"),
                    ]
                )
            ],
            protocols: [],
            categories: [
                makeCategory(
                    name: "Extras",
                    className: "FixtureController",
                    methods: [makeMethod("categoryMethod", encoding: "v16@0:8")]
                )
            ]
        )

        let report = ObjectiveCPatchabilityAnalyzer.report(for: metadata)

        XCTAssertEqual(report.summary.classCount, 1)
        XCTAssertEqual(report.summary.categoryCount, 1)
        XCTAssertEqual(report.summary.classMethodCount, 9)
        XCTAssertEqual(report.summary.categoryMethodCount, 1)
        XCTAssertEqual(report.summary.patchableClassMethodCount, 3)
        XCTAssertEqual(report.summary.patchableCategoryMethodCount, 1)
        XCTAssertEqual(report.summary.unavailableClassMethodCount, 6)
        XCTAssertEqual(report.summary.unavailableCategoryMethodCount, 0)
        XCTAssertEqual(report.summary.methodCount, 10)
        XCTAssertEqual(report.summary.patchableMethodCount, 4)
        XCTAssertEqual(report.summary.unavailableMethodCount, 6)
        XCTAssertEqual(
            report.summary.unsupportedTypeCounts,
            [
                ObjectiveCUnsupportedTypeCount(
                    role: .argument,
                    typeKind: .structure,
                    typeEncoding: "{Point=dd}",
                    count: 1
                ),
                ObjectiveCUnsupportedTypeCount(
                    role: .returnValue,
                    typeKind: .structure,
                    typeEncoding: "{Point=dd}",
                    count: 1
                ),
            ]
        )

        let bySelector = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.selector, $0) })
        let supported = try XCTUnwrap(bySelector["supported"])
        XCTAssertTrue(supported.isPatchable)
        XCTAssertTrue(supported.isAvailableInEditor)
        XCTAssertEqual(supported.signature?.returnType.kind, .boolean)
        XCTAssertEqual(
            supported.compatibleActions,
            PatchActionCompatibility.allowedActions(for: try decode("B16@0:8"))
        )

        let category = try XCTUnwrap(bySelector["categoryMethod"])
        XCTAssertTrue(category.isPatchable)
        XCTAssertFalse(category.isAvailableInEditor)
        XCTAssertEqual(category.categoryName, "Extras")

        assertIssue(.missingTypeEncoding, for: "missing", in: bySelector)
        assertIssue(.invalidTypeEncoding, for: "invalid", in: bySelector)
        assertIssue(.invalidImplicitArguments, for: "badImplicit", in: bySelector)
        assertIssue(.selectorArgumentCountMismatch, for: "takesValue:", in: bySelector)
        XCTAssertTrue(try XCTUnwrap(bySelector["floatingResult"]).isPatchable)
        XCTAssertTrue(try XCTUnwrap(bySelector["takesFloating:"]).isPatchable)
        assertIssue(.unsupportedReturnType, for: "structureResult", in: bySelector)
        assertIssue(.unsupportedArgumentType, for: "takesStructure:", in: bySelector)

        let unsupportedArgument = try XCTUnwrap(bySelector["takesStructure:"]?.issues.first)
        XCTAssertEqual(unsupportedArgument.typeKind, .structure)
        XCTAssertEqual(unsupportedArgument.typeEncoding, "{Point=dd}")
        XCTAssertEqual(unsupportedArgument.argumentPosition, 1)
    }

    func testIssueCountsAreOrderedByFrequencyThenStableCode() {
        let metadata = ObjectiveCMetadata(
            classes: [
                makeClass(
                    name: "Fixture",
                    methods: [
                        makeMethod("structureOne", encoding: "{Point=dd}16@0:8"),
                        makeMethod("structureTwo", encoding: "{Point=dd}16@0:8"),
                        makeMethod("missingOne", encoding: nil),
                        makeMethod("missingTwo", encoding: nil),
                        makeMethod("invalid", encoding: "x"),
                    ]
                )
            ],
            protocols: [],
            categories: []
        )

        XCTAssertEqual(
            ObjectiveCPatchabilityAnalyzer.report(for: metadata).summary.issueCounts,
            [
                ObjectiveCPatchabilityIssueCount(code: .missingTypeEncoding, count: 2),
                ObjectiveCPatchabilityIssueCount(code: .unsupportedReturnType, count: 2),
                ObjectiveCPatchabilityIssueCount(code: .invalidTypeEncoding, count: 1),
            ]
        )
    }

    func testOpaqueArgumentsAndKnownStructuresBecomePatchableWithoutArbitraryStructs() throws {
        let metadata = ObjectiveCMetadata(
            classes: [
                makeClass(
                    name: "ComplexFixture",
                    methods: [
                        makeMethod("runBlock:", encoding: "v24@0:8@?16"),
                        makeMethod("usePointer:", encoding: "v24@0:8^v16"),
                        makeMethod(
                            "useRect:",
                            encoding: "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16"
                        ),
                        makeMethod("range", encoding: "{_NSRange=QQ}16@0:8"),
                        makeMethod("unknownPoint", encoding: "{Point=dd}16@0:8"),
                    ]
                )
            ],
            protocols: [],
            categories: []
        )

        let report = ObjectiveCPatchabilityAnalyzer.report(for: metadata)
        let methods = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.selector, $0) })

        XCTAssertEqual(report.summary.patchableMethodCount, 4)
        XCTAssertTrue(try XCTUnwrap(methods["runBlock:"]).isPatchable)
        XCTAssertTrue(try XCTUnwrap(methods["usePointer:"]).isPatchable)
        XCTAssertTrue(try XCTUnwrap(methods["useRect:"]).isPatchable)
        XCTAssertTrue(try XCTUnwrap(methods["range"]).isPatchable)
        assertIssue(.unsupportedReturnType, for: "unknownPoint", in: methods)
    }

    func testReportOrderingAndCodableRoundTripAreDeterministic() throws {
        let metadata = ObjectiveCMetadata(
            classes: [
                makeClass(name: "Zulu", methods: [makeMethod("zeta", encoding: "v@:")]),
                makeClass(name: "Alpha", methods: [makeMethod("base", encoding: "v@:")]),
            ],
            protocols: [],
            categories: [
                makeCategory(
                    name: "Extras",
                    className: "Alpha",
                    methods: [makeMethod("addition", encoding: "v@:")]
                )
            ]
        )
        let report = ObjectiveCPatchabilityAnalyzer.report(for: metadata)

        XCTAssertEqual(report.methods.map(\.className), ["Alpha", "Alpha", "Zulu"])
        XCTAssertEqual(report.methods.map(\.selector), ["base", "addition", "zeta"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let first = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(ObjectiveCPatchabilityReport.self, from: first)
        let second = try encoder.encode(decoded)

        XCTAssertEqual(decoded, report)
        XCTAssertEqual(second, first)
    }

    private func assertIssue(
        _ code: ObjectiveCMethodPatchabilityIssueCode,
        for selector: String,
        in methods: [String: ObjectiveCMethodPatchability],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(methods[selector]?.issues.map(\.code), [code], file: file, line: line)
        XCTAssertEqual(methods[selector]?.compatibleActions, [], file: file, line: line)
        XCTAssertFalse(methods[selector]?.isPatchable ?? true, file: file, line: line)
    }

    private func makeClass(name: String, methods: [ObjectiveCMethod]) -> ObjectiveCClass {
        ObjectiveCClass(
            id: "class-\(name)",
            name: name,
            superclassName: "NSObject",
            imageName: "Fixture",
            isLikelyAppDefined: true,
            isObjectiveCVisibleSwift: false,
            instanceMethods: methods,
            classMethods: [],
            properties: [],
            ivars: [],
            protocols: []
        )
    }

    private func makeCategory(
        name: String,
        className: String,
        methods: [ObjectiveCMethod]
    ) -> ObjectiveCCategory {
        ObjectiveCCategory(
            id: "category-\(name)",
            name: name,
            className: className,
            instanceMethods: methods,
            classMethods: [],
            properties: [],
            protocols: []
        )
    }

    private func makeMethod(_ selector: String, encoding: String?) -> ObjectiveCMethod {
        ObjectiveCMethod(
            id: "method-\(selector)",
            selector: selector,
            kind: .instance,
            typeEncoding: encoding,
            implementationAddress: nil
        )
    }

    private func decode(_ encoding: String) throws -> ObjectiveCMethodSignature {
        try ObjectiveCTypeEncodingDecoder.decodeMethodSignature(encoding)
    }
}
