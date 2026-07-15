import MachPatchCore

enum ObjectiveCMetadataNormalizer {
    static func normalize(
        _ raw: RawObjectiveCMetadata,
        imageName: String
    ) -> ObjectiveCMetadata {
        ObjectiveCMetadata(
            classes: raw.classes.map { normalize($0, imageName: imageName) }
                .sorted { $0.name < $1.name },
            protocols: raw.protocols.map(normalize).sorted { $0.name < $1.name },
            categories: raw.categories.map(normalize).sorted {
                ($0.className, $0.name) < ($1.className, $1.name)
            }
        )
    }

    private static func normalize(
        _ raw: RawObjectiveCClass,
        imageName: String
    ) -> ObjectiveCClass {
        let owner = "class:\(raw.name)"
        return ObjectiveCClass(
            id: owner,
            name: raw.name,
            superclassName: raw.superclassName,
            imageName: imageName,
            isLikelyAppDefined: !ClassOriginHeuristic.isKnownThirdParty(raw.name),
            isObjectiveCVisibleSwift: raw.name.hasPrefix("_Tt"),
            instanceMethods: methods(raw.instanceMethods, owner: owner),
            classMethods: methods(raw.classMethods, owner: owner),
            properties: properties(raw.properties, owner: owner),
            ivars: raw.ivars.map {
                ObjectiveCIvar(
                    id: "ivar:\(owner):\($0.name)",
                    name: $0.name,
                    typeEncoding: $0.typeEncoding,
                    offset: $0.offset
                )
            }.sorted { $0.name < $1.name },
            protocols: Array(Set(raw.protocols)).sorted()
        )
    }

    private static func normalize(_ raw: RawObjectiveCProtocol) -> ObjectiveCProtocol {
        let owner = "protocol:\(raw.name)"
        return ObjectiveCProtocol(
            id: owner,
            name: raw.name,
            adoptedProtocols: Array(Set(raw.adoptedProtocols)).sorted(),
            methods: raw.methods.map {
                ObjectiveCProtocolMethod(
                    method: method($0.method, owner: owner),
                    isRequired: $0.isRequired
                )
            }.sorted {
                if $0.isRequired != $1.isRequired { return $0.isRequired && !$1.isRequired }
                if $0.method.kind != $1.method.kind {
                    return $0.method.kind.rawValue < $1.method.kind.rawValue
                }
                return $0.method.selector < $1.method.selector
            },
            properties: properties(raw.properties, owner: owner)
        )
    }

    private static func normalize(_ raw: RawObjectiveCCategory) -> ObjectiveCCategory {
        let owner = "category:\(raw.className):\(raw.name)"
        return ObjectiveCCategory(
            id: owner,
            name: raw.name,
            className: raw.className,
            instanceMethods: methods(raw.instanceMethods, owner: owner),
            classMethods: methods(raw.classMethods, owner: owner),
            properties: properties(raw.properties, owner: owner),
            protocols: Array(Set(raw.protocols)).sorted()
        )
    }

    private static func methods(
        _ rawMethods: [RawObjectiveCMethod],
        owner: String
    ) -> [ObjectiveCMethod] {
        rawMethods.map { method($0, owner: owner) }.sorted {
            if $0.selector != $1.selector { return $0.selector < $1.selector }
            return ($0.implementationAddress ?? 0) < ($1.implementationAddress ?? 0)
        }
    }

    private static func method(
        _ raw: RawObjectiveCMethod,
        owner: String
    ) -> ObjectiveCMethod {
        ObjectiveCMethod(
            id: "method:\(owner):\(raw.kind.rawValue):\(raw.selector)",
            selector: raw.selector,
            kind: raw.kind,
            typeEncoding: raw.typeEncoding,
            implementationAddress: raw.implementationAddress
        )
    }

    private static func properties(
        _ rawProperties: [RawObjectiveCProperty],
        owner: String
    ) -> [ObjectiveCProperty] {
        rawProperties.map {
            ObjectiveCProperty(
                id: "property:\(owner):\($0.name)",
                name: $0.name,
                attributes: $0.attributes
            )
        }.sorted { $0.name < $1.name }
    }
}

private enum ClassOriginHeuristic {
    private static let prefixes = [
        "ABT",
        "Adjust",
        "AFS",
        "AL",
        "Amplitude",
        "AppsFlyer",
        "Branch",
        "FB",
        "FIR",
        "GAD",
        "GoogleMobileAds",
        "IronSource",
        "MA",
        "OneSignal",
        "SDWebImage",
        "Sentry",
        "Unity",
        "Vungle",
    ]

    private static let containedMarkers = [
        "AppLovin",
        "Facebook",
        "Firebase",
        "GoogleMobileAds",
        "IronSource",
        "Sentry",
        "VungleAdsSDK",
    ]

    static func isKnownThirdParty(_ className: String) -> Bool {
        prefixes.contains { className.hasPrefix($0) }
            || containedMarkers.contains { className.contains($0) }
    }
}
