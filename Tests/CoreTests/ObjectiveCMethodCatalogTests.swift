import MachPatchCore
import XCTest

final class ObjectiveCMethodCatalogTests: XCTestCase {
    func testCanonicalizesClassAndCategoryDeclarationsByRuntimeIdentity() throws {
        let classMethod = method(
            id: "class-method",
            selector: "featureEnabled",
            encoding: "B16@0:8",
            address: 0x1000
        )
        let categoryMethod = method(
            id: "category-method",
            selector: "featureEnabled",
            encoding: "B16@0:8",
            address: 0x2000
        )
        let metadata = ObjectiveCMetadata(
            classes: [objectiveCClass(name: "Fixture", methods: [classMethod])],
            protocols: [],
            categories: [
                category(name: "Extras", className: "Fixture", methods: [categoryMethod]),
                category(
                    name: "External",
                    className: "ExternalController",
                    methods: [method(id: "external", selector: "run", encoding: "v16@0:8")]
                ),
            ]
        )

        XCTAssertEqual(
            ObjectiveCMethodCatalog.ownerClassNames(in: metadata),
            ["ExternalController", "Fixture"]
        )
        let canonical = try XCTUnwrap(
            ObjectiveCMethodCatalog.method(
                forClassNamed: "Fixture",
                kind: .instance,
                selector: "featureEnabled",
                in: metadata
            )
        )

        XCTAssertEqual(canonical.typeEncoding, "B16@0:8")
        XCTAssertNil(canonical.implementationAddress)
        XCTAssertTrue(canonical.hasClassDeclaration)
        XCTAssertEqual(canonical.categoryNames, ["Extras"])
        XCTAssertFalse(canonical.hasConflictingTypeEncodings)
        XCTAssertEqual(canonical.declarations.map(\.categoryName), [nil, "Extras"])
        XCTAssertEqual(canonical.method.id, canonical.id)

        let external = ObjectiveCMethodCatalog.methods(
            forClassNamed: "ExternalController",
            in: metadata
        )
        XCTAssertEqual(external.map(\.selector), ["run"])
        XCTAssertFalse(try XCTUnwrap(external.first).hasClassDeclaration)
    }

    func testConflictingTypeEncodingsRemainVisibleButCannotBeCanonicalized() throws {
        let metadata = ObjectiveCMetadata(
            classes: [],
            protocols: [],
            categories: [
                category(
                    name: "One",
                    className: "Fixture",
                    methods: [method(id: "one", selector: "value", encoding: "q16@0:8")]
                ),
                category(
                    name: "Two",
                    className: "Fixture",
                    methods: [method(id: "two", selector: "value", encoding: "d16@0:8")]
                ),
            ]
        )

        let canonical = try XCTUnwrap(
            ObjectiveCMethodCatalog.methods(forClassNamed: "Fixture", in: metadata).first
        )
        XCTAssertNil(canonical.typeEncoding)
        XCTAssertTrue(canonical.hasConflictingTypeEncodings)
        XCTAssertEqual(canonical.conflictingTypeEncodings, ["d16@0:8", "q16@0:8"])
        XCTAssertEqual(canonical.categoryNames, ["One", "Two"])
    }

    func testPropertyAccessorSelectorsHonorCustomAndReadOnlyAttributes() {
        let defaultProperty = ObjectiveCProperty(
            id: "default",
            name: "featureEnabled",
            attributes: "TB,N,V_featureEnabled"
        )
        XCTAssertEqual(
            defaultProperty.accessorSelectors,
            ObjectiveCPropertyAccessorSelectors(
                getter: "featureEnabled",
                setter: "setFeatureEnabled:",
                isReadOnly: false
            )
        )

        let customProperty = ObjectiveCProperty(
            id: "custom",
            name: "title",
            attributes: "T@\"NSString\",GdisplayTitle,SapplyTitle:,N"
        )
        XCTAssertEqual(customProperty.accessorSelectors.getter, "displayTitle")
        XCTAssertEqual(customProperty.accessorSelectors.setter, "applyTitle:")

        let readOnlyProperty = ObjectiveCProperty(
            id: "readonly",
            name: "identifier",
            attributes: "T@\"NSString\",R,N"
        )
        XCTAssertEqual(readOnlyProperty.accessorSelectors.getter, "identifier")
        XCTAssertNil(readOnlyProperty.accessorSelectors.setter)
        XCTAssertTrue(readOnlyProperty.accessorSelectors.isReadOnly)
    }

    private func objectiveCClass(
        name: String,
        methods: [ObjectiveCMethod]
    ) -> ObjectiveCClass {
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

    private func category(
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

    private func method(
        id: String,
        selector: String,
        encoding: String?,
        address: UInt64? = nil
    ) -> ObjectiveCMethod {
        ObjectiveCMethod(
            id: id,
            selector: selector,
            kind: .instance,
            typeEncoding: encoding,
            implementationAddress: address
        )
    }
}
