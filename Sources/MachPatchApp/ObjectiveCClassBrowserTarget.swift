import MachPatchCore

struct ObjectiveCPropertyBrowserItem: Equatable, Identifiable {
    let property: ObjectiveCProperty
    let categoryName: String?

    var id: String {
        "\(categoryName ?? "class"):\(property.id)"
    }
}

struct ObjectiveCClassBrowserTarget: Equatable, Identifiable {
    let id: String
    let name: String
    let superclassName: String?
    let imageName: String
    let isLikelyAppDefined: Bool
    let isObjectiveCVisibleSwift: Bool
    let isCategoryOnly: Bool
    let methods: [ObjectiveCCanonicalMethod]
    let properties: [ObjectiveCPropertyBrowserItem]
    let ivars: [ObjectiveCIvar]
    let protocols: [String]
    let categoryNames: [String]

    var instanceMethods: [ObjectiveCCanonicalMethod] {
        methods.filter { $0.kind == .instance }
    }

    var classMethods: [ObjectiveCCanonicalMethod] {
        methods.filter { $0.kind == .class }
    }

    func method(
        kind: ObjectiveCMethodKind,
        selector: String
    ) -> ObjectiveCCanonicalMethod? {
        methods.first { $0.kind == kind && $0.selector == selector }
    }
}

enum ObjectiveCClassBrowserCatalog {
    static func targets(for analysis: ObjectiveCAnalysis) -> [ObjectiveCClassBrowserTarget] {
        let metadata = analysis.metadata
        return ObjectiveCMethodCatalog.ownerClassNames(in: metadata).map { className in
            let objectiveCClass = metadata.classes.first { $0.name == className }
            let categories = metadata.categories.filter { $0.className == className }
            let properties =
                (objectiveCClass?.properties.map {
                    ObjectiveCPropertyBrowserItem(property: $0, categoryName: nil)
                } ?? [])
                + categories.flatMap { category in
                    category.properties.map {
                        ObjectiveCPropertyBrowserItem(
                            property: $0,
                            categoryName: category.name
                        )
                    }
                }
            return ObjectiveCClassBrowserTarget(
                id: objectiveCClass?.id ?? "category-owner:\(className)",
                name: className,
                superclassName: objectiveCClass?.superclassName,
                imageName: objectiveCClass?.imageName ?? analysis.target.executableName,
                isLikelyAppDefined: objectiveCClass?.isLikelyAppDefined ?? false,
                isObjectiveCVisibleSwift: objectiveCClass?.isObjectiveCVisibleSwift ?? false,
                isCategoryOnly: objectiveCClass == nil,
                methods: ObjectiveCMethodCatalog.methods(
                    forClassNamed: className,
                    in: metadata
                ),
                properties: properties.sorted(by: propertyOrdering),
                ivars: objectiveCClass?.ivars ?? [],
                protocols: Array(
                    Set((objectiveCClass?.protocols ?? []) + categories.flatMap(\.protocols))
                ).sorted(),
                categoryNames: categories.map(\.name).sorted()
            )
        }
    }

    private static func propertyOrdering(
        _ lhs: ObjectiveCPropertyBrowserItem,
        _ rhs: ObjectiveCPropertyBrowserItem
    ) -> Bool {
        if lhs.property.name != rhs.property.name {
            return lhs.property.name < rhs.property.name
        }
        switch (lhs.categoryName, rhs.categoryName) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (.some(let lhsName), .some(let rhsName)):
            return lhsName < rhsName
        case (nil, nil):
            return lhs.id < rhs.id
        }
    }
}
