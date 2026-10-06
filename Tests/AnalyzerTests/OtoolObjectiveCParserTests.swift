import MachPatchCore
import XCTest

@testable import MachPatchAnalyzer

final class OtoolObjectiveCParserTests: XCTestCase {
    func testParsesAndResolvesClassesProtocolsAndCategories() throws {
        let parsed = try OtoolObjectiveCParser().parse(Self.otoolFixture)
        XCTAssertEqual(parsed.classes.count, 1)
        XCTAssertEqual(parsed.protocols.count, 1)
        XCTAssertEqual(parsed.categories.count, 1)

        let resolved = try OtoolObjectiveCSelectorResolver().resolve(
            parsed,
            methodNamesOutput: Self.methodNamesFixture,
            selectorReferencesOutput: Self.selectorReferencesFixture
        )

        let objectiveCClass = try XCTUnwrap(resolved.classes.first)
        XCTAssertEqual(objectiveCClass.name, "FixtureManager")
        XCTAssertEqual(objectiveCClass.superclassName, "NSObject")
        XCTAssertEqual(objectiveCClass.protocols, ["FixtureProtocol"])
        XCTAssertEqual(objectiveCClass.instanceMethods.map(\.selector), ["featureEnabled"])
        XCTAssertEqual(objectiveCClass.instanceMethods.first?.typeEncoding, "B16@0:8")
        XCTAssertEqual(objectiveCClass.instanceMethods.first?.implementationAddress, 0x1000)
        XCTAssertEqual(objectiveCClass.classMethods.map(\.selector), ["sharedManager"])
        XCTAssertEqual(objectiveCClass.properties.first?.name, "enabled")
        XCTAssertEqual(objectiveCClass.properties.first?.attributes, "TB,N,V_enabled")
        XCTAssertEqual(objectiveCClass.ivars.first?.name, "_enabled")
        XCTAssertEqual(objectiveCClass.ivars.first?.typeEncoding, "B")
        XCTAssertEqual(objectiveCClass.ivars.first?.offset, 8)

        let protocolDefinition = try XCTUnwrap(resolved.protocols.first)
        XCTAssertEqual(protocolDefinition.name, "FixtureProtocol")
        XCTAssertEqual(protocolDefinition.methods.count, 2)
        XCTAssertEqual(protocolDefinition.methods[0].method.selector, "featureEnabled")
        XCTAssertTrue(protocolDefinition.methods[0].isRequired)
        XCTAssertEqual(protocolDefinition.methods[1].method.selector, "optionalReset")
        XCTAssertFalse(protocolDefinition.methods[1].isRequired)

        let category = try XCTUnwrap(resolved.categories.first)
        XCTAssertEqual(category.name, "Testing")
        XCTAssertEqual(category.className, "FixtureManager")
        XCTAssertEqual(category.instanceMethods.map(\.selector), ["reset"])
    }

    func testNormalizerSortsAndLabelsMetadataDeterministically() throws {
        let parsed = try OtoolObjectiveCParser().parse(Self.otoolFixture)
        var thirdParty = RawObjectiveCClass(name: "ABTExperiment")
        thirdParty.instanceMethods = [RawObjectiveCMethod(selector: "zMethod")]
        var raw = parsed
        raw.classes.append(thirdParty)
        let resolved = try OtoolObjectiveCSelectorResolver().resolve(
            raw,
            methodNamesOutput: Self.methodNamesFixture,
            selectorReferencesOutput: Self.selectorReferencesFixture
        )

        let metadata = ObjectiveCMetadataNormalizer.normalize(
            resolved,
            imageName: "Fixture"
        )
        XCTAssertEqual(metadata.classes.map(\.name), ["ABTExperiment", "FixtureManager"])
        XCTAssertFalse(metadata.classes[0].isLikelyAppDefined)
        XCTAssertTrue(metadata.classes[1].isLikelyAppDefined)
        XCTAssertEqual(metadata.classes[1].imageName, "Fixture")
        XCTAssertEqual(metadata.classes[1].id, "class:FixtureManager")
        XCTAssertEqual(
            metadata.classes[1].instanceMethods.first?.id,
            "method:class:FixtureManager:instance:featureEnabled"
        )
    }

    func testTreatsOtoolPointerAnnotationsAsUnresolvedSelectors() throws {
        let output = """
            Fixture:
            Contents of (__DATA_CONST,__objc_classlist) section
            0000000100300000 0x100300100
                isa        0x100300200
                superclass 0x0 _OBJC_CLASS_$_NSObject
                data       0x100300300
                    name           0x100100100 FixtureManager
                    baseMethods    0x100300400
                        entsize 12 (relative)
                        count   1
                        name    0x100200000 (not in a literal section, file)
                        types   0x100110000 B16@0:8
                        imp     0x1000
            """

        let parsed = try OtoolObjectiveCParser().parse(output)
        let method = try XCTUnwrap(parsed.classes.first?.instanceMethods.first)
        XCTAssertEqual(method.selector, "")
        XCTAssertEqual(method.selectorReference, 0x100200000)
    }

    func testRejectsUnresolvableSelectorReference() throws {
        var raw = RawObjectiveCMetadata()
        raw.classes = [
            RawObjectiveCClass(
                name: "Fixture",
                instanceMethods: [
                    RawObjectiveCMethod(selectorReference: 0xDEAD, kind: .instance)
                ]
            )
        ]

        XCTAssertThrowsError(
            try OtoolObjectiveCSelectorResolver().resolve(
                raw,
                methodNamesOutput: "",
                selectorReferencesOutput: ""
            )
        )
    }

    func testRejectsAmbiguousLowAddressSelectorMapping() throws {
        var raw = RawObjectiveCMetadata()
        raw.classes = [
            RawObjectiveCClass(
                name: "Fixture",
                instanceMethods: [
                    RawObjectiveCMethod(selectorReference: 0x4000, kind: .instance)
                ]
            )
        ]
        let methodNames = """
            Contents of (__TEXT,__objc_methname) section
            0000000100000010  firstSelector
            0000000200000010  secondSelector
            """
        let selectorReferences = """
            Contents of (__DATA,__objc_selrefs) section
            0000000000004000  0x8000000000000010 (not in a literal section)
            """

        XCTAssertThrowsError(
            try OtoolObjectiveCSelectorResolver().resolve(
                raw,
                methodNamesOutput: methodNames,
                selectorReferencesOutput: selectorReferences
            )
        )
    }

    private static let methodNamesFixture = """
        Fixture:
        Contents of (__TEXT,__objc_methname) section
        0000000100100000  featureEnabled
        0000000100100020  sharedManager
        0000000100100040  optionalReset
        0000000100100060  reset
        """

    private static let selectorReferencesFixture = """
        Fixture:
        Contents of (__DATA,__objc_selrefs) section
        0000000100200000  0x1000000000100000 (not in a literal section)
        0000000100200008  0x1000000000100020 (not in a literal section)
        0000000100200010  0x1000000000100040 (not in a literal section)
        0000000100200018  0x1000000000100060 (not in a literal section)
        """

    private static let otoolFixture = """
        Fixture:
        Contents of (__DATA_CONST,__objc_classlist) section
        0000000100300000 0x100300100
            isa        0x100300200
            superclass 0x0 _OBJC_CLASS_$_NSObject
            data       0x100300300
                name           0x100100100 FixtureManager
                baseMethods    0x100300400
                    entsize 12 (relative)
                    count   1
                    name    0x10 (0x100200000)
                    types   0x20 (0x100110000) B16@0:8
                    imp     0x30 (0x1000)
                baseProtocols  0x100300500
                    count    1
                    list[0]  0x100300600
                        isa       0x0
                        name      0x100100200 FixtureProtocol
                ivars          0x100300700
                    entsize   32
                    count     1
                    offset    0x100300800 8
                    name      0x100100300 _enabled
                    type      0x100100310 B
                    alignment 0
                    size      1
                baseProperties 0x100300900
                    entsize    16
                    count      1
                    name       0x100100400 enabled
                    attributes 0x100100410 TB,N,V_enabled
        Meta Class
            data       0x100301000
                name           0x100100100 FixtureManager
                baseMethods    0x100301100
                    entsize 12 (relative)
                    count   1
                    name    0x10 (0x100200008)
                    types   0x20 (0x100110020) @16@0:8
                    imp     0x30 (0x1020)
        Contents of (__DATA_CONST,__objc_protolist) section
        0000000100400000 0x100400100
            isa       0x0
            name      0x100100200 FixtureProtocol
            protocols 0x0
            instanceMethods 0x100400200
                entsize 12 (relative)
                count   1
                name    0x10 (0x100200000)
                types   0x20 (0x100110000) B16@0:8
                imp     0x0
            optionalClassMethods 0x100400300
                entsize 12 (relative)
                count   1
                name    0x10 (0x100200010)
                types   0x20 (0x100110040) v16@0:8
                imp     0x0
        Contents of (__DATA_CONST,__objc_catlist) section
        0000000100500000 0x100500100
            name      0x100100500 Testing
            cls       0x0 _OBJC_CLASS_$_FixtureManager
            instanceMethods 0x100500200
                entsize 12 (relative)
                count   1
                name    0x10 (0x100200018)
                types   0x20 (0x100110060) v16@0:8
                imp     0x30 (0x1040)
            classMethods 0x0
            protocols 0x0
            instanceProperties 0x0
        """
}
