import Foundation
import MachPatchCore

struct OtoolObjectiveCParser {
    func parse(_ output: String) throws -> RawObjectiveCMetadata {
        let sections = splitSections(output)
        var metadata = RawObjectiveCMetadata()

        for section in sections {
            if section.name.contains("__objc_classlist") {
                metadata.classes.append(contentsOf: parseClasses(section.lines))
            } else if section.name.contains("__objc_protolist") {
                metadata.protocols.append(contentsOf: parseProtocols(section.lines))
            } else if section.name.contains("__objc_catlist") {
                metadata.categories.append(contentsOf: parseCategories(section.lines))
            }
        }
        return metadata
    }

    private func splitSections(_ output: String) -> [Section] {
        var sections: [Section] = []
        var currentName: String?
        var currentLines: [Line] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(rawLine)
            if text.hasPrefix("Contents of (") {
                if let currentName {
                    sections.append(Section(name: currentName, lines: currentLines))
                }
                currentName = text
                currentLines = []
            } else if currentName != nil {
                currentLines.append(Line(text))
            }
        }
        if let currentName {
            sections.append(Section(name: currentName, lines: currentLines))
        }
        return sections
    }

    private func parseClasses(_ lines: [Line]) -> [RawObjectiveCClass] {
        records(in: lines).compactMap { record in
            let metaIndex = record.firstIndex { $0.indent == 0 && $0.text == "Meta Class" }
            let instanceLines = Array(record[..<(metaIndex ?? record.endIndex)])
            let metaLines = metaIndex.map { Array(record[record.index(after: $0)...]) } ?? []

            guard let name = field("name", indent: 8, in: instanceLines) else { return nil }
            var result = RawObjectiveCClass(name: name)
            if let superclass = field("superclass", indent: 4, in: instanceLines) {
                result.superclassName = stripSymbolPrefix(superclass, prefix: "_OBJC_CLASS_$_")
            }
            result.instanceMethods = parseMethods(
                block(named: "baseMethods", indent: 8, in: instanceLines),
                entryIndent: 12,
                kind: .instance
            )
            result.classMethods = parseMethods(
                block(named: "baseMethods", indent: 8, in: metaLines),
                entryIndent: 12,
                kind: .class
            )
            result.properties = parseProperties(
                block(named: "baseProperties", indent: 8, in: instanceLines),
                entryIndent: 12
            )
            result.ivars = parseIvars(
                block(named: "ivars", indent: 8, in: instanceLines),
                entryIndent: 12
            )
            result.protocols = parseAdoptedProtocols(
                block(named: "baseProtocols", indent: 8, in: instanceLines),
                listIndent: 12,
                nameIndent: 16
            )
            return result
        }
    }

    private func parseProtocols(_ lines: [Line]) -> [RawObjectiveCProtocol] {
        records(in: lines).compactMap { record in
            guard let name = field("name", indent: 4, in: record) else { return nil }
            var result = RawObjectiveCProtocol(name: name)
            result.adoptedProtocols = parseAdoptedProtocols(
                block(named: "protocols", indent: 4, in: record),
                listIndent: 8,
                nameIndent: 12
            )

            let methodGroups: [(String, ObjectiveCMethodKind, Bool)] = [
                ("instanceMethods", .instance, true),
                ("classMethods", .class, true),
                ("optionalInstanceMethods", .instance, false),
                ("optionalClassMethods", .class, false),
            ]
            for (fieldName, kind, isRequired) in methodGroups {
                let methods = parseMethods(
                    block(named: fieldName, indent: 4, in: record),
                    entryIndent: 8,
                    kind: kind
                )
                result.methods.append(
                    contentsOf: methods.map {
                        RawObjectiveCProtocolMethod(method: $0, isRequired: isRequired)
                    }
                )
            }
            result.properties = parseProperties(
                block(named: "instanceProperties", indent: 4, in: record),
                entryIndent: 8
            )
            return result
        }
    }

    private func parseCategories(_ lines: [Line]) -> [RawObjectiveCCategory] {
        records(in: lines).compactMap { record in
            guard let name = field("name", indent: 4, in: record),
                let classSymbol = field("cls", indent: 4, in: record)
            else { return nil }

            var result = RawObjectiveCCategory(
                name: name,
                className: stripSymbolPrefix(classSymbol, prefix: "_OBJC_CLASS_$_")
            )
            result.instanceMethods = parseMethods(
                block(named: "instanceMethods", indent: 4, in: record),
                entryIndent: 8,
                kind: .instance
            )
            result.classMethods = parseMethods(
                block(named: "classMethods", indent: 4, in: record),
                entryIndent: 8,
                kind: .class
            )
            result.properties = parseProperties(
                block(named: "instanceProperties", indent: 4, in: record),
                entryIndent: 8
            )
            result.protocols = parseAdoptedProtocols(
                block(named: "protocols", indent: 4, in: record),
                listIndent: 8,
                nameIndent: 12
            )
            return result
        }
    }

    private func parseMethods(
        _ lines: [Line],
        entryIndent: Int,
        kind: ObjectiveCMethodKind
    ) -> [RawObjectiveCMethod] {
        var methods: [RawObjectiveCMethod] = []
        var current: RawObjectiveCMethod?

        for line in lines where line.indent == entryIndent {
            if let selector = line.value(for: "name") {
                if let current, !current.selector.isEmpty || current.selectorReference != nil {
                    methods.append(current)
                }
                current = RawObjectiveCMethod(selector: selector, kind: kind)
            } else if line.hasField("name"), let reference = line.lastHexValue {
                if let current, !current.selector.isEmpty || current.selectorReference != nil {
                    methods.append(current)
                }
                current = RawObjectiveCMethod(
                    selectorReference: reference,
                    kind: kind
                )
            } else if let typeEncoding = line.value(for: "types") {
                if !typeEncoding.hasPrefix("0x") { current?.typeEncoding = typeEncoding }
            } else if line.hasField("imp") {
                current?.implementationAddress = line.lastHexValue.flatMap { $0 == 0 ? nil : $0 }
            }
        }
        if let current, !current.selector.isEmpty || current.selectorReference != nil {
            methods.append(current)
        }
        return methods
    }

    private func parseProperties(
        _ lines: [Line],
        entryIndent: Int
    ) -> [RawObjectiveCProperty] {
        var properties: [RawObjectiveCProperty] = []
        var current: RawObjectiveCProperty?

        for line in lines where line.indent == entryIndent {
            if let name = line.value(for: "name") {
                if let current, !current.name.isEmpty { properties.append(current) }
                current = RawObjectiveCProperty(name: name)
            } else if let attributes = line.value(for: "attributes") {
                current?.attributes = attributes
            }
        }
        if let current, !current.name.isEmpty { properties.append(current) }
        return properties
    }

    private func parseIvars(
        _ lines: [Line],
        entryIndent: Int
    ) -> [RawObjectiveCIvar] {
        var ivars: [RawObjectiveCIvar] = []
        var current: RawObjectiveCIvar?

        for line in lines where line.indent == entryIndent {
            if line.hasField("offset") {
                if let current, !current.name.isEmpty { ivars.append(current) }
                current = RawObjectiveCIvar(offset: line.lastIntegerValue)
            } else if let name = line.value(for: "name") {
                current?.name = name
            } else if let type = line.value(for: "type") {
                current?.typeEncoding = type
            }
        }
        if let current, !current.name.isEmpty { ivars.append(current) }
        return ivars
    }

    private func parseAdoptedProtocols(
        _ lines: [Line],
        listIndent: Int,
        nameIndent: Int
    ) -> [String] {
        var names: [String] = []
        var awaitingName = false

        for line in lines {
            if line.indent == listIndent, line.text.hasPrefix("list[") {
                awaitingName = true
            } else if awaitingName, line.indent == nameIndent,
                let name = line.value(for: "name")
            {
                names.append(name)
                awaitingName = false
            } else if line.indent <= listIndent, !line.text.hasPrefix("list[") {
                awaitingName = false
            }
        }
        return names
    }

    private func records(in lines: [Line]) -> [[Line]] {
        var records: [[Line]] = []
        var current: [Line] = []

        for line in lines {
            if line.indent == 0, line.isAddressRecord {
                if !current.isEmpty { records.append(current) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { records.append(current) }
        return records
    }

    private func block(named name: String, indent: Int, in lines: [Line]) -> [Line] {
        guard let start = lines.firstIndex(where: { $0.indent == indent && $0.hasField(name) })
        else {
            return []
        }
        let contentStart = lines.index(after: start)
        let end =
            lines[contentStart...].firstIndex(where: { $0.indent <= indent }) ?? lines.endIndex
        return Array(lines[contentStart..<end])
    }

    private func field(_ name: String, indent: Int, in lines: [Line]) -> String? {
        lines.first { $0.indent == indent && $0.hasField(name) }?.value(for: name)
    }

    private func stripSymbolPrefix(_ value: String, prefix: String) -> String {
        value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }
}

private struct Section {
    let name: String
    let lines: [Line]
}

private struct Line {
    let indent: Int
    let text: String

    init(_ raw: String) {
        indent = raw.prefix { $0 == " " }.count
        text = raw.trimmingCharacters(in: .whitespaces)
    }

    var isAddressRecord: Bool {
        let fields = text.split(whereSeparator: \.isWhitespace)
        return fields.count >= 2 && fields[0].allSatisfy(\.isHexDigit)
            && fields[1].hasPrefix("0x")
    }

    var lastHexValue: UInt64? {
        let matches = text.split(whereSeparator: \.isWhitespace).compactMap { token -> UInt64? in
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard cleaned.hasPrefix("0x") else { return nil }
            return UInt64(cleaned.dropFirst(2), radix: 16)
        }
        return matches.last
    }

    var lastIntegerValue: UInt64? {
        guard let token = text.split(whereSeparator: \.isWhitespace).last else { return nil }
        if token.hasPrefix("0x") { return UInt64(token.dropFirst(2), radix: 16) }
        return UInt64(token)
    }

    func hasField(_ name: String) -> Bool {
        text == name || text.hasPrefix("\(name) ")
    }

    func value(for name: String) -> String? {
        guard hasField(name) else { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }
        let valueFields = fields.dropFirst()
        let candidate = valueFields.last.map(String.init) ?? ""
        guard candidate != "__mh_execute_header" else { return nil }
        let pointerCandidate = candidate.trimmingCharacters(
            in: CharacterSet(charactersIn: "()")
        )
        if pointerCandidate.hasPrefix("0x") { return nil }

        if valueFields.first?.hasPrefix("0x") == true,
            valueFields.dropFirst().first?.hasPrefix("(") == true,
            candidate.hasSuffix(")")
        {
            return nil
        }
        return candidate
    }
}
