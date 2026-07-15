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
        XCTAssertEqual(report.summary.classMethodCount, 7)
        XCTAssertEqual(report.summary.categoryMethodCount, 1)
        XCTAssertEqual(report.summary.patchableClassMethodCount, 1)
        XCTAssertEqual(report.summary.patchableCategoryMethodCount, 1)
        XCTAssertEqual(report.summary.unavailableClassMethodCount, 6)
        XCTAssertEqual(report.summary.unavailableCategoryMethodCount, 0)
        XCTAssertEqual(report.summary.methodCount, 8)
        XCTAssertEqual(report.summary.patchableMethodCount, 2)
        XCTAssertEqual(report.summary.unavailableMethodCount, 6)
        XCTAssertEqual(
            report.summary.unsupportedTypeCounts,
            [
                ObjectiveCUnsupportedTypeCount(
                    role: .argument,
                    typeKind: .double,
                    typeEncoding: "d",
                    count: 1
                ),
                ObjectiveCUnsupportedTypeCount(
                    role: .returnValue,
                    typeKind: .double,
                    typeEncoding: "d",
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
        assertIssue(.unsupportedReturnType, for: "floatingResult", in: bySelector)
        assertIssue(.unsupportedArgumentType, for: "takesFloating:", in: bySelector)

        let unsupportedArgument = try XCTUnwrap(bySelector["takesFloating:"]?.issues.first)
        XCTAssertEqual(unsupportedArgument.typeKind, .double)
        XCTAssertEqual(unsupportedArgument.typeEncoding, "d")
        XCTAssertEqual(unsupportedArgument.argumentPosition, 1)
    }

    func testIssueCountsAreOrderedByFrequencyThenStableCode() {
        let metadata = ObjectiveCMetadata(
            classes: [
                makeClass(
                    name: "Fixture",
                    methods: [
                        makeMethod("doubleOne", encoding: "d16@0:8"),
                        makeMethod("doubleTwo", encoding: "d16@0:8"),
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
