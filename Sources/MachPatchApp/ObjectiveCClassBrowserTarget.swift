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
    let isLikelyThirdPartySDK: Bool
    let isUIKitSubclass: Bool
    let isObjectiveCVisibleSwift: Bool
    let isDeclaredBySelectedImage: Bool
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

struct ObjectiveCClassSearchMatch: Equatable {
    let matchesClassName: Bool
    let superclassName: String?
    let imageName: String?
    let methods: [ObjectiveCCanonicalMethod]
    let categoryNames: [String]

    var hasMatch: Bool {
        matchesClassName || superclassName != nil || imageName != nil || !methods.isEmpty
            || !categoryNames.isEmpty
    }
}

enum ObjectiveCClassBrowserCatalog {
    static func targets(for analysis: ObjectiveCAnalysis) -> [ObjectiveCClassBrowserTarget] {
        let metadata = analysis.metadata
        let classesByName = Dictionary(
            metadata.classes.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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
                imageName: objectiveCClass?.imageName ?? analysis.image.executableName,
                isLikelyAppDefined: objectiveCClass?.isLikelyAppDefined ?? false,
                isLikelyThirdPartySDK: objectiveCClass.map { !$0.isLikelyAppDefined } ?? false,
                isUIKitSubclass: objectiveCClass.map {
                    isUIKitSubclass($0, classesByName: classesByName)
                } ?? false,
                isObjectiveCVisibleSwift: objectiveCClass?.isObjectiveCVisibleSwift ?? false,
                isDeclaredBySelectedImage: objectiveCClass != nil,
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

    private static func isUIKitSubclass(
        _ objectiveCClass: ObjectiveCClass,
        classesByName: [String: ObjectiveCClass]
    ) -> Bool {
        var visited: Set<String> = []
        var superclassName = objectiveCClass.superclassName
        while let currentName = superclassName, visited.insert(currentName).inserted {
            if currentName.hasPrefix("UI") || currentName.hasPrefix("_UI") {
                return true
            }
            superclassName = classesByName[currentName]?.superclassName
        }
        return false
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
