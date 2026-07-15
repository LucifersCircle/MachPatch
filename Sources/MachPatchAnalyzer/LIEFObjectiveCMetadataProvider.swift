import Foundation
import MachPatchCore

struct LIEFObjectiveCMetadataProvider: ObjectiveCMetadataProvider {
    let backend: ObjectiveCAnalyzerBackend = .liefExtended

    func availability() -> ProviderAvailability {
        guard let helperURL else {
            return .unavailable("bundled helper is missing")
        }
        do {
            let result = try ExternalCommandRunner.run(
                executableURL: URL(filePath: "/usr/bin/env"),
                arguments: ["python3", helperURL.path, "--probe"]
            )
            guard result.terminationStatus == 0 else {
                return .unavailable(errorMessage(from: result))
            }
            let probe = try JSONDecoder().decode(Probe.self, from: result.standardOutput)
            return probe.available
                ? .available
                : .unavailable(probe.reason ?? "Objective-C support is unavailable")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func extractMetadata(
        from executableURL: URL,
        slice: MachOSlice
    ) throws -> RawObjectiveCMetadata {
        guard let helperURL else {
            throw ObjectiveCProviderError("bundled LIEF helper is missing")
        }
        let result = try ExternalCommandRunner.run(
            executableURL: URL(filePath: "/usr/bin/env"),
            arguments: [
                "python3",
                helperURL.path,
                executableURL.path,
                "--slice-index",
                String(slice.index),
            ]
        )
        guard result.terminationStatus == 0 else {
            throw ObjectiveCProviderError(errorMessage(from: result))
        }
        let wire = try JSONDecoder().decode(WireMetadata.self, from: result.standardOutput)
        return wire.rawMetadata
    }

    private var helperURL: URL? {
        Bundle.module.url(forResource: "lief_objc_analyzer", withExtension: "py")
    }

    private func errorMessage(from result: ExternalCommandResult) -> String {
        let error = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return error.isEmpty
            ? "LIEF helper exited with status \(result.terminationStatus)"
            : error
    }
}

private struct Probe: Decodable {
    let available: Bool
    let reason: String?
}

private struct WireMetadata: Decodable {
    let classes: [WireClass]
    let protocols: [WireProtocol]
    let categories: [WireCategory]

    var rawMetadata: RawObjectiveCMetadata {
        RawObjectiveCMetadata(
            classes: classes.map(\.rawClass),
            protocols: protocols.map(\.rawProtocol),
            categories: categories.map(\.rawCategory)
        )
    }
}

private struct WireClass: Decodable {
    let name: String
    let superclassName: String?
    let methods: [WireMethod]
    let properties: [WireProperty]
    let ivars: [WireIvar]
    let protocols: [String]

    var rawClass: RawObjectiveCClass {
        RawObjectiveCClass(
            name: name,
            superclassName: superclassName,
            instanceMethods: methods.filter(\.isInstance).map(\.rawMethod),
            classMethods: methods.filter { !$0.isInstance }.map(\.rawMethod),
            properties: properties.map(\.rawProperty),
            ivars: ivars.map(\.rawIvar),
            protocols: protocols
        )
    }
}

private struct WireMethod: Decodable {
    let name: String
    let isInstance: Bool
    let typeEncoding: String?
    let address: UInt64?

    var rawMethod: RawObjectiveCMethod {
        RawObjectiveCMethod(
            selector: name,
            kind: isInstance ? .instance : .class,
            typeEncoding: typeEncoding,
            implementationAddress: address == 0 ? nil : address
        )
    }
}

private struct WireProperty: Decodable {
    let name: String
    let attributes: String

    var rawProperty: RawObjectiveCProperty {
        RawObjectiveCProperty(name: name, attributes: attributes)
    }
}

private struct WireIvar: Decodable {
    let name: String
    let typeEncoding: String

    var rawIvar: RawObjectiveCIvar {
        RawObjectiveCIvar(name: name, typeEncoding: typeEncoding)
    }
}

private struct WireProtocol: Decodable {
    let name: String
    let methods: [WireProtocolMethod]
    let properties: [WireProperty]
    let adoptedProtocols: [String]

    var rawProtocol: RawObjectiveCProtocol {
        RawObjectiveCProtocol(
            name: name,
            adoptedProtocols: adoptedProtocols,
            methods: methods.map(\.rawProtocolMethod),
            properties: properties.map(\.rawProperty)
        )
    }
}

private struct WireProtocolMethod: Decodable {
    let method: WireMethod
    let isRequired: Bool

    var rawProtocolMethod: RawObjectiveCProtocolMethod {
        RawObjectiveCProtocolMethod(method: method.rawMethod, isRequired: isRequired)
    }
}

private struct WireCategory: Decodable {
    let name: String
    let className: String
    let methods: [WireMethod]
    let properties: [WireProperty]
    let protocols: [String]

    var rawCategory: RawObjectiveCCategory {
        RawObjectiveCCategory(
            name: name,
            className: className,
            instanceMethods: methods.filter(\.isInstance).map(\.rawMethod),
            classMethods: methods.filter { !$0.isInstance }.map(\.rawMethod),
            properties: properties.map(\.rawProperty),
            protocols: protocols
        )
    }
}
