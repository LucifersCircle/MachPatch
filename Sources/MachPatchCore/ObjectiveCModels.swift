public struct ObjectiveCAnalysis: Codable, Equatable, Sendable {
    public let target: ResolvedTarget
    public let image: ResolvedImage
    public let sliceIndex: Int
    public let architecture: MachOArchitecture
    public let backend: ObjectiveCAnalyzerBackend
    public let warnings: [String]
    public let metadata: ObjectiveCMetadata

    public init(
        target: ResolvedTarget,
        image: ResolvedImage? = nil,
        sliceIndex: Int,
        architecture: MachOArchitecture,
        backend: ObjectiveCAnalyzerBackend,
        warnings: [String],
        metadata: ObjectiveCMetadata
    ) {
        self.target = target
        self.image = image ?? target.primaryImage
        self.sliceIndex = sliceIndex
        self.architecture = architecture
        self.backend = backend
        self.warnings = warnings
        self.metadata = metadata
    }
}

public enum ObjectiveCAnalyzerBackend: String, Codable, Equatable, Sendable {
    case liefExtended
    case otool
}

public struct ObjectiveCMetadata: Codable, Equatable, Sendable {
    public let classes: [ObjectiveCClass]
    public let protocols: [ObjectiveCProtocol]
    public let categories: [ObjectiveCCategory]

    public init(
        classes: [ObjectiveCClass],
        protocols: [ObjectiveCProtocol],
        categories: [ObjectiveCCategory]
    ) {
        self.classes = classes
        self.protocols = protocols
        self.categories = categories
    }
}

public struct ObjectiveCClass: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let superclassName: String?
    public let imageName: String?
    public let isLikelyAppDefined: Bool
    public let isObjectiveCVisibleSwift: Bool
    public let instanceMethods: [ObjectiveCMethod]
    public let classMethods: [ObjectiveCMethod]
    public let properties: [ObjectiveCProperty]
    public let ivars: [ObjectiveCIvar]
    public let protocols: [String]

    public init(
        id: String,
        name: String,
        superclassName: String?,
        imageName: String?,
        isLikelyAppDefined: Bool,
        isObjectiveCVisibleSwift: Bool,
        instanceMethods: [ObjectiveCMethod],
        classMethods: [ObjectiveCMethod],
        properties: [ObjectiveCProperty],
        ivars: [ObjectiveCIvar],
        protocols: [String]
    ) {
        self.id = id
        self.name = name
        self.superclassName = superclassName
        self.imageName = imageName
        self.isLikelyAppDefined = isLikelyAppDefined
        self.isObjectiveCVisibleSwift = isObjectiveCVisibleSwift
        self.instanceMethods = instanceMethods
        self.classMethods = classMethods
        self.properties = properties
        self.ivars = ivars
        self.protocols = protocols
    }
}

public struct ObjectiveCMethod: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let selector: String
    public let kind: ObjectiveCMethodKind
    public let typeEncoding: String?
    public let implementationAddress: UInt64?

    public init(
        id: String,
        selector: String,
        kind: ObjectiveCMethodKind,
        typeEncoding: String?,
        implementationAddress: UInt64?
    ) {
        self.id = id
        self.selector = selector
        self.kind = kind
        self.typeEncoding = typeEncoding
        self.implementationAddress = implementationAddress
    }
}

public enum ObjectiveCMethodKind: String, Codable, Equatable, Hashable, Sendable {
    case instance
    case `class`
}

public struct ObjectiveCProperty: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let attributes: String

    public init(id: String, name: String, attributes: String) {
        self.id = id
        self.name = name
        self.attributes = attributes
    }
}

public struct ObjectiveCIvar: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let typeEncoding: String
    public let offset: UInt64?

    public init(id: String, name: String, typeEncoding: String, offset: UInt64?) {
        self.id = id
        self.name = name
        self.typeEncoding = typeEncoding
        self.offset = offset
    }
}

public struct ObjectiveCProtocol: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let adoptedProtocols: [String]
    public let methods: [ObjectiveCProtocolMethod]
    public let properties: [ObjectiveCProperty]

    public init(
        id: String,
        name: String,
        adoptedProtocols: [String],
        methods: [ObjectiveCProtocolMethod],
        properties: [ObjectiveCProperty]
    ) {
        self.id = id
        self.name = name
        self.adoptedProtocols = adoptedProtocols
        self.methods = methods
        self.properties = properties
    }
}

public struct ObjectiveCProtocolMethod: Codable, Equatable, Sendable {
    public let method: ObjectiveCMethod
    public let isRequired: Bool

    public init(method: ObjectiveCMethod, isRequired: Bool) {
        self.method = method
        self.isRequired = isRequired
    }
}

public struct ObjectiveCCategory: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let className: String
    public let instanceMethods: [ObjectiveCMethod]
    public let classMethods: [ObjectiveCMethod]
    public let properties: [ObjectiveCProperty]
    public let protocols: [String]

    public init(
        id: String,
        name: String,
        className: String,
        instanceMethods: [ObjectiveCMethod],
        classMethods: [ObjectiveCMethod],
        properties: [ObjectiveCProperty],
        protocols: [String]
    ) {
        self.id = id
        self.name = name
        self.className = className
        self.instanceMethods = instanceMethods
        self.classMethods = classMethods
        self.properties = properties
        self.protocols = protocols
    }
}
