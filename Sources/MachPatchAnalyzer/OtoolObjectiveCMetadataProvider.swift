import Foundation
import MachPatchCore

struct OtoolObjectiveCMetadataProvider: ObjectiveCMetadataProvider {
    let backend: ObjectiveCAnalyzerBackend = .otool

    func availability() -> ProviderAvailability {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
            ? .available
            : .unavailable("xcrun is not available")
    }

    func extractMetadata(
        from executableURL: URL,
        slice: MachOSlice
    ) throws -> RawObjectiveCMetadata {
        let verboseOutput = try runOtool(
            arguments: ["-ov"],
            executableURL: executableURL,
            slice: slice
        )
        let rawMetadata = try OtoolObjectiveCParser().parse(verboseOutput)
        guard hasUnresolvedSelectors(rawMetadata) else { return rawMetadata }

        let methodNamesOutput = try runOtool(
            arguments: ["-v", "-s", "__TEXT", "__objc_methname"],
            executableURL: executableURL,
            slice: slice
        )
        let selectorSegments = ["__DATA", "__DATA_CONST", "__AUTH", "__AUTH_CONST"]
        var selectorReferencesOutput = ""
        for segment in selectorSegments {
            selectorReferencesOutput += try runOtool(
                arguments: ["-v", "-s", segment, "__objc_selrefs"],
                executableURL: executableURL,
                slice: slice
            )
        }

        return try OtoolObjectiveCSelectorResolver().resolve(
            rawMetadata,
            methodNamesOutput: methodNamesOutput,
            selectorReferencesOutput: selectorReferencesOutput
        )
    }

    private func runOtool(
        arguments: [String],
        executableURL: URL,
        slice: MachOSlice
    ) throws -> String {
        var commandArguments = ["otool"]
        if let architectureName = architectureName(for: slice.architecture) {
            commandArguments.append(contentsOf: ["-arch", architectureName])
        }
        commandArguments.append(contentsOf: arguments)
        commandArguments.append(executableURL.path)

        let result = try ExternalCommandRunner.run(
            executableURL: URL(filePath: "/usr/bin/xcrun"),
            arguments: commandArguments
        )
        guard result.terminationStatus == 0 else {
            let message = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ObjectiveCProviderError(
                message.isEmpty
                    ? "otool exited with status \(result.terminationStatus)"
                    : message
            )
        }
        guard let output = String(data: result.standardOutput, encoding: .utf8) else {
            throw ObjectiveCProviderError("otool output is not valid UTF-8")
        }
        return output
    }

    private func hasUnresolvedSelectors(_ metadata: RawObjectiveCMetadata) -> Bool {
        metadata.classes.contains {
            ($0.instanceMethods + $0.classMethods).contains { $0.selector.isEmpty }
        }
            || metadata.protocols.contains {
                $0.methods.contains { $0.method.selector.isEmpty }
            }
            || metadata.categories.contains {
                ($0.instanceMethods + $0.classMethods).contains { $0.selector.isEmpty }
            }
    }

    private func architectureName(for architecture: MachOArchitecture) -> String? {
        switch architecture {
        case .arm64: "arm64"
        case .arm64e, .arm64eLegacy: "arm64e"
        case .arm6432: "arm64_32"
        case .armv7: "armv7"
        case .armv7s: "armv7s"
        case .x8664: "x86_64"
        case .unknown: nil
        }
    }
}

struct ObjectiveCProviderError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
