import Foundation

struct OtoolObjectiveCSelectorResolver {
    func resolve(
        _ metadata: RawObjectiveCMetadata,
        methodNamesOutput: String,
        selectorReferencesOutput: String
    ) throws -> RawObjectiveCMetadata {
        let strings = parseMethodNames(methodNamesOutput)
        let references = parseSelectorReferences(
            selectorReferencesOutput,
            strings: strings
        )
        var result = metadata

        for classIndex in result.classes.indices {
            result.classes[classIndex].instanceMethods = try resolve(
                result.classes[classIndex].instanceMethods,
                strings: strings,
                references: references
            )
            result.classes[classIndex].classMethods = try resolve(
                result.classes[classIndex].classMethods,
                strings: strings,
                references: references
            )
        }
        for protocolIndex in result.protocols.indices {
            for methodIndex in result.protocols[protocolIndex].methods.indices {
                result.protocols[protocolIndex].methods[methodIndex].method = try resolve(
                    result.protocols[protocolIndex].methods[methodIndex].method,
                    strings: strings,
                    references: references
                )
            }
        }
        for categoryIndex in result.categories.indices {
            result.categories[categoryIndex].instanceMethods = try resolve(
                result.categories[categoryIndex].instanceMethods,
                strings: strings,
                references: references
            )
            result.categories[categoryIndex].classMethods = try resolve(
                result.categories[categoryIndex].classMethods,
                strings: strings,
                references: references
            )
        }
        return result
    }

    private func resolve(
        _ methods: [RawObjectiveCMethod],
        strings: StringTable,
        references: [UInt64: String]
    ) throws -> [RawObjectiveCMethod] {
        try methods.map { try resolve($0, strings: strings, references: references) }
    }

    private func resolve(
        _ method: RawObjectiveCMethod,
        strings: StringTable,
        references: [UInt64: String]
    ) throws -> RawObjectiveCMethod {
        guard method.selector.isEmpty else { return method }
        guard let reference = method.selectorReference else {
            throw ObjectiveCProviderError(
                "method is missing both a selector and selector reference")
        }

        let selector =
            references[reference]
            ?? strings.fullAddress[reference]
            ?? strings.lowAddress[reference & 0xFFFF_FFFF]
        guard let selector else {
            throw ObjectiveCProviderError(
                "selector reference 0x\(String(reference, radix: 16)) could not be resolved"
            )
        }

        var resolved = method
        resolved.selector = selector
        return resolved
    }

    private func parseMethodNames(_ output: String) -> StringTable {
        var table = StringTable()
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(where: \.isWhitespace) else { continue }
            let addressText = line[..<separator]
            guard let address = UInt64(addressText, radix: 16) else { continue }
            let value = line[separator...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            table.insert(value, at: address)
        }
        return table
    }

    private func parseSelectorReferences(
        _ output: String,
        strings: StringTable
    ) -> [UInt64: String] {
        var result: [UInt64: String] = [:]
        for rawLine in output.split(separator: "\n") {
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                let referenceAddress = UInt64(fields[0], radix: 16)
            else { continue }

            let pointerText = fields[1]
            guard pointerText.hasPrefix("0x"),
                let pointer = UInt64(pointerText.dropFirst(2), radix: 16)
            else { continue }

            if fields.count >= 3, !fields[2].hasPrefix("(") {
                result[referenceAddress] = fields.dropFirst(2).joined(separator: " ")
            } else if let value = strings.fullAddress[pointer]
                ?? strings.lowAddress[pointer & 0xFFFF_FFFF]
            {
                result[referenceAddress] = value
            }
        }
        return result
    }
}

private struct StringTable {
    var fullAddress: [UInt64: String] = [:]
    var lowAddress: [UInt64: String] = [:]
    private var ambiguousLowAddresses: Set<UInt64> = []

    mutating func insert(_ value: String, at address: UInt64) {
        fullAddress[address] = value

        let lowAddress = address & 0xFFFF_FFFF
        guard !ambiguousLowAddresses.contains(lowAddress) else { return }
        if let existing = self.lowAddress[lowAddress], existing != value {
            self.lowAddress.removeValue(forKey: lowAddress)
            ambiguousLowAddresses.insert(lowAddress)
        } else {
            self.lowAddress[lowAddress] = value
        }
    }
}
