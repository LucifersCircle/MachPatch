import Foundation

enum UnresolvedSymbolParser {
    static func parse(
        _ output: String,
        defaultArchitecture: String?,
        allowedProviders: Set<String>
    ) -> [UnresolvedSymbol] {
        var architecture = defaultArchitecture
        var symbols: [UnresolvedSymbol] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let value = architectureHeader(in: line) {
                architecture = value
                continue
            }
            guard line.contains("undefined") || line.hasPrefix("U ") else { continue }

            let provider = providerName(in: line)
            let withoutProvider: String
            if let providerRange = line.range(of: " (from ", options: .backwards) {
                withoutProvider = String(line[..<providerRange.lowerBound])
            } else {
                withoutProvider = line
            }
            guard let name = withoutProvider.split(whereSeparator: \.isWhitespace).last else {
                continue
            }
            let symbolName = String(name)
            symbols.append(
                UnresolvedSymbol(
                    architecture: architecture,
                    name: symbolName,
                    provider: provider,
                    classification: classify(
                        symbolName,
                        provider: provider,
                        allowedProviders: allowedProviders
                    )
                )
            )
        }
        return symbols
    }

    private static func architectureHeader(in line: String) -> String? {
        guard let start = line.range(of: "(for architecture "),
            let end = line[start.upperBound...].firstIndex(of: ")")
        else { return nil }
        return String(line[start.upperBound..<end])
    }

    private static func providerName(in line: String) -> String? {
        guard let start = line.range(of: " (from ", options: .backwards),
            line.hasSuffix(")")
        else { return nil }
        return String(line[start.upperBound..<line.index(before: line.endIndex)])
    }

    private static func classify(
        _ symbol: String,
        provider: String?,
        allowedProviders: Set<String>
    ) -> UnresolvedSymbolClassification {
        if CompatibilityPolicy.containsForbiddenMarker(symbol)
            || provider.map(CompatibilityPolicy.containsForbiddenMarker) == true
        {
            return .unexpectedExternal
        }
        if let provider, !allowedProviders.contains(provider) {
            return .unexpectedExternal
        }

        let runtimePrefixes = [
            "_objc_", "_class_", "_sel_", "_method_", "_object_", "_protocol_",
            "_ivar_", "_imp_", "_dispatch_", "___", "_dyld_", "_os_", "_swift_",
        ]
        let runtimeNames: Set<String> = [
            "_abort", "_calloc", "_dlclose", "_dlopen", "_dlsym", "_free", "_malloc",
            "_memcmp", "_memcpy", "_memmove", "_memset", "_strcmp", "_strlen",
        ]
        if runtimePrefixes.contains(where: symbol.hasPrefix) || runtimeNames.contains(symbol) {
            return .expectedAppleRuntime
        }

        let frameworkPrefixes = [
            "_NS", "_UI", "_CF", "_CG", "_CA", "_Sec", "_AV", "_WK", "_Audio", "_$s",
        ]
        if frameworkPrefixes.contains(where: symbol.hasPrefix)
            || provider != nil
        {
            return .expectedAppleFramework
        }
        return .unexpectedExternal
    }
}
