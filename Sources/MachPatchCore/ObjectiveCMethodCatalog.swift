public struct ObjectiveCMethodDeclaration: Codable, Equatable, Identifiable, Sendable {
    public let method: ObjectiveCMethod
    public let categoryName: String?

    public init(method: ObjectiveCMethod, categoryName: String?) {
        self.method = method
        self.categoryName = categoryName
    }

    public var id: String {
        "\(categoryName ?? "class"):\(method.id)"
    }
}

public struct ObjectiveCCanonicalMethod: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let className: String
    public let selector: String
    public let kind: ObjectiveCMethodKind
    public let typeEncoding: String?
    public let implementationAddress: UInt64?
    public let declarations: [ObjectiveCMethodDeclaration]
    public let conflictingTypeEncodings: [String]

    public init(
        id: String,
        className: String,
        selector: String,
        kind: ObjectiveCMethodKind,
        typeEncoding: String?,
        implementationAddress: UInt64?,
        declarations: [ObjectiveCMethodDeclaration],
        conflictingTypeEncodings: [String]
    ) {
        self.id = id
        self.className = className
        self.selector = selector
        self.kind = kind
        self.typeEncoding = typeEncoding
        self.implementationAddress = implementationAddress
        self.declarations = declarations
        self.conflictingTypeEncodings = conflictingTypeEncodings
    }

    public var method: ObjectiveCMethod {
        ObjectiveCMethod(
            id: id,
            selector: selector,
            kind: kind,
            typeEncoding: typeEncoding,
            implementationAddress: implementationAddress
        )
    }

    public var categoryNames: [String] {
        Array(Set(declarations.compactMap(\.categoryName))).sorted()
    }

    public var hasClassDeclaration: Bool {
        declarations.contains { $0.categoryName == nil }
    }

    public var hasConflictingTypeEncodings: Bool {
        conflictingTypeEncodings.count > 1
    }
}

public enum ObjectiveCMethodCatalog {
    public static func ownerClassNames(in metadata: ObjectiveCMetadata) -> [String] {
        Array(
            Set(metadata.classes.map(\.name) + metadata.categories.map(\.className))
        ).sorted()
    }

    public static func methods(
        forClassNamed className: String,
        in metadata: ObjectiveCMetadata
    ) -> [ObjectiveCCanonicalMethod] {
        var grouped: [MethodKey: [ObjectiveCMethodDeclaration]] = [:]

        if let objectiveCClass = metadata.classes.first(where: { $0.name == className }) {
            for method in objectiveCClass.instanceMethods + objectiveCClass.classMethods {
                grouped[MethodKey(kind: method.kind, selector: method.selector), default: []]
                    .append(ObjectiveCMethodDeclaration(method: method, categoryName: nil))
            }
        }

        for category in metadata.categories where category.className == className {
            for method in category.instanceMethods + category.classMethods {
                grouped[MethodKey(kind: method.kind, selector: method.selector), default: []]
                    .append(
                        ObjectiveCMethodDeclaration(
                            method: method,
                            categoryName: category.name
                        )
                    )
            }
        }

        return grouped.map { key, declarations in
            canonicalMethod(
                className: className,
                key: key,
                declarations: declarations
            )
        }.sorted(by: methodOrdering)
    }

    public static func method(
        forClassNamed className: String,
        kind: ObjectiveCMethodKind,
        selector: String,
        in metadata: ObjectiveCMetadata
    ) -> ObjectiveCCanonicalMethod? {
        methods(forClassNamed: className, in: metadata).first {
            $0.kind == kind && $0.selector == selector
        }
    }

    public static func identifier(
        className: String,
        kind: ObjectiveCMethodKind,
        selector: String
    ) -> String {
        "canonical:\(className):\(kind.rawValue):\(selector)"
    }

    private static func canonicalMethod(
        className: String,
        key: MethodKey,
        declarations: [ObjectiveCMethodDeclaration]
    ) -> ObjectiveCCanonicalMethod {
        let sortedDeclarations = declarations.sorted(by: declarationOrdering)
        let encodings = Array(Set(declarations.compactMap(\.method.typeEncoding))).sorted()
        let addresses = Array(Set(declarations.compactMap(\.method.implementationAddress))).sorted()
        return ObjectiveCCanonicalMethod(
            id: identifier(className: className, kind: key.kind, selector: key.selector),
            className: className,
            selector: key.selector,
            kind: key.kind,
            typeEncoding: encodings.count == 1 ? encodings[0] : nil,
            implementationAddress: addresses.count == 1 ? addresses[0] : nil,
            declarations: sortedDeclarations,
            conflictingTypeEncodings: encodings.count > 1 ? encodings : []
        )
    }

    private static func methodOrdering(
        _ lhs: ObjectiveCCanonicalMethod,
        _ rhs: ObjectiveCCanonicalMethod
    ) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.selector == rhs.selector
            ? lhs.id < rhs.id
            : lhs.selector < rhs.selector
    }

    private static func declarationOrdering(
        _ lhs: ObjectiveCMethodDeclaration,
        _ rhs: ObjectiveCMethodDeclaration
    ) -> Bool {
        switch (lhs.categoryName, rhs.categoryName) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (.some(let lhsName), .some(let rhsName)) where lhsName != rhsName:
            return lhsName < rhsName
        default:
            return lhs.method.id < rhs.method.id
        }
    }

    private struct MethodKey: Hashable {
        let kind: ObjectiveCMethodKind
        let selector: String
    }
}

public struct ObjectiveCPropertyAccessorSelectors: Codable, Equatable, Sendable {
    public let getter: String?
    public let setter: String?
    public let isReadOnly: Bool

    public init(getter: String?, setter: String?, isReadOnly: Bool) {
        self.getter = getter
        self.setter = setter
        self.isReadOnly = isReadOnly
    }
}

extension ObjectiveCProperty {
    public var accessorSelectors: ObjectiveCPropertyAccessorSelectors {
        let components = attributes.split(separator: ",").map(String.init)
        let customGetter = components.first { $0.hasPrefix("G") && $0.count > 1 }?.dropFirst()
        let customSetter = components.first { $0.hasPrefix("S") && $0.count > 1 }?.dropFirst()
        let isReadOnly = components.contains("R")
        let defaultSetter: String?
        if name.isEmpty {
            defaultSetter = nil
        } else {
            defaultSetter = "set\(name.prefix(1).uppercased())\(name.dropFirst()):"
        }
        return ObjectiveCPropertyAccessorSelectors(
            getter: customGetter.map(String.init) ?? (name.isEmpty ? nil : name),
            setter: isReadOnly ? nil : customSetter.map(String.init) ?? defaultSetter,
            isReadOnly: isReadOnly
        )
    }
}
