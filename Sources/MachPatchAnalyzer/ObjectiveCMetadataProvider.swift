import Foundation
import MachPatchCore

protocol ObjectiveCMetadataProvider: Sendable {
    var backend: ObjectiveCAnalyzerBackend { get }

    func availability() -> ProviderAvailability
    func extractMetadata(
        from executableURL: URL,
        slice: MachOSlice
    ) throws -> RawObjectiveCMetadata
}

enum ProviderAvailability: Equatable {
    case available
    case unavailable(String)
}

struct RawObjectiveCMetadata: Equatable {
    var classes: [RawObjectiveCClass] = []
    var protocols: [RawObjectiveCProtocol] = []
    var categories: [RawObjectiveCCategory] = []
}

struct RawObjectiveCClass: Equatable {
    var name = ""
    var superclassName: String?
    var instanceMethods: [RawObjectiveCMethod] = []
    var classMethods: [RawObjectiveCMethod] = []
    var properties: [RawObjectiveCProperty] = []
    var ivars: [RawObjectiveCIvar] = []
    var protocols: [String] = []
}

struct RawObjectiveCMethod: Equatable {
    var selector = ""
    var selectorReference: UInt64?
    var kind: ObjectiveCMethodKind = .instance
    var typeEncoding: String?
    var implementationAddress: UInt64?
}

struct RawObjectiveCProperty: Equatable {
    var name = ""
    var attributes = ""
}

struct RawObjectiveCIvar: Equatable {
    var name = ""
    var typeEncoding = ""
    var offset: UInt64?
}

struct RawObjectiveCProtocol: Equatable {
    var name = ""
    var adoptedProtocols: [String] = []
    var methods: [RawObjectiveCProtocolMethod] = []
    var properties: [RawObjectiveCProperty] = []
}

struct RawObjectiveCProtocolMethod: Equatable {
    var method = RawObjectiveCMethod()
    var isRequired = true
}

struct RawObjectiveCCategory: Equatable {
    var name = ""
    var className = ""
    var instanceMethods: [RawObjectiveCMethod] = []
    var classMethods: [RawObjectiveCMethod] = []
    var properties: [RawObjectiveCProperty] = []
    var protocols: [String] = []
}
