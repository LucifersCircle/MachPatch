import Darwin
import Foundation
import MachPatchAnalyzer
import MachPatchBuilder
import MachPatchCore
import MachPatchGenerator
import MachPatchVerifier

@main
struct MachPatchCommand {
    private static let help = """
        OVERVIEW: Inspect iOS applications and build native runtime patches.

        USAGE: machpatch <command> [arguments]

        COMMANDS:
          resolve <path>         Resolve an IPA, .app, or Mach-O executable.
          inspect <path> [--json]
                                 Inspect every Mach-O slice and load command.
          architectures <path>  Report buildable device slices and architecture modes.
          classes <path> [--json]
                                 List normalized Objective-C classes.
          methods <path> <class> [--json]
                                 List methods declared by an Objective-C class.
          patchability <path> [--json]
                                 Report editable and unsupported Objective-C methods.
          validate-project <project> [--target <path>]
                                 Validate a patch project, optionally against a target.
          generate <project> --output <directory>
                                 Generate deterministic Objective-C patch source.
          build <project> --output <directory> [--arch <mode>]
                                 Build an iPhoneOS patch dylib; mode is automatic, arm64,
                                 arm64e, or universal.
          verify <dylib> [--target <path>] [--json]
                                 Audit LiveContainer compatibility, optionally against a target.

        OPTIONS:
          --version             Show the MachPatch version.
          -h, --help            Show help information.

        Run 'machpatch --help' to get started.
        """

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case nil, "-h", "--help":
            print(help)
        case "--version":
            print("machpatch \(MachPatchVersion.current)")
        case "resolve":
            guard arguments.count == 2 else {
                writeError("Usage: machpatch resolve <path>\n")
                exit(EX_USAGE)
            }
            resolve(path: arguments[1])
        case "inspect":
            guard
                arguments.count == 2
                    || (arguments.count == 3 && arguments[2] == "--json")
            else {
                writeError("Usage: machpatch inspect <path> [--json]\n")
                exit(EX_USAGE)
            }
            inspect(path: arguments[1])
        case "architectures":
            guard arguments.count == 2 else {
                writeError("Usage: machpatch architectures <path>\n")
                exit(EX_USAGE)
            }
            architectures(path: arguments[1])
        case "classes":
            guard
                arguments.count == 2
                    || (arguments.count == 3 && arguments[2] == "--json")
            else {
                writeError("Usage: machpatch classes <path> [--json]\n")
                exit(EX_USAGE)
            }
            classes(path: arguments[1])
        case "methods":
            guard
                arguments.count == 3
                    || (arguments.count == 4 && arguments[3] == "--json")
            else {
                writeError("Usage: machpatch methods <path> <class> [--json]\n")
                exit(EX_USAGE)
            }
            methods(path: arguments[1], className: arguments[2])
        case "patchability":
            guard
                arguments.count == 2
                    || (arguments.count == 3 && arguments[2] == "--json")
            else {
                writeError("Usage: machpatch patchability <path> [--json]\n")
                exit(EX_USAGE)
            }
            patchability(path: arguments[1], json: arguments.count == 3)
        case "validate-project":
            guard
                arguments.count == 2
                    || (arguments.count == 4 && arguments[2] == "--target")
            else {
                writeError(
                    "Usage: machpatch validate-project <project.json> [--target <path>]\n"
                )
                exit(EX_USAGE)
            }
            validateProject(
                projectPath: arguments[1],
                targetPath: arguments.count == 4 ? arguments[3] : nil
            )
        case "generate":
            guard arguments.count == 4, arguments[2] == "--output" else {
                writeError("Usage: machpatch generate <project.json> --output <directory>\n")
                exit(EX_USAGE)
            }
            generate(projectPath: arguments[1], outputPath: arguments[3])
        case "build":
            guard let options = parseBuildOptions(arguments) else {
                writeError(
                    "Usage: machpatch build <project.json> --output <directory> [--arch automatic|arm64|arm64e|universal]\n"
                )
                exit(EX_USAGE)
            }
            build(
                projectPath: arguments[1],
                outputPath: options.outputPath,
                architectureMode: options.architectureMode
            )
        case "verify":
            guard let options = parseVerifyOptions(arguments) else {
                writeError(
                    "Usage: machpatch verify <dylib> [--target <path>] [--json]\n"
                )
                exit(EX_USAGE)
            }
            verify(
                dylibPath: arguments[1],
                targetPath: options.targetPath,
                json: options.json
            )
        default:
            writeError("Unknown command or option: \(arguments[0])\n\n\(help)\n")
            exit(EX_USAGE)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func resolve(path: String) {
        do {
            try InputResolver().withResolvedTarget(at: URL(filePath: path)) { target in
                try writeJSON(target)
            }
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func inspect(path: String) {
        do {
            try InputResolver().withResolvedTarget(at: URL(filePath: path)) { target in
                try writeJSON(try MachOInspector().inspect(target))
            }
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func architectures(path: String) {
        do {
            try InputResolver().withResolvedTarget(at: URL(filePath: path)) { target in
                let inspection = try MachOInspector().inspect(target)
                try writeJSON(
                    ArchitectureCommandOutput(
                        target: target,
                        report: ArchitectureResolver.report(for: inspection.slices)
                    )
                )
            }
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func writeJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func classes(path: String) {
        do {
            try InputResolver().withResolvedTarget(at: URL(filePath: path)) { target in
                let analysis = try ObjectiveCAnalyzer().analyze(target)
                try writeJSON(
                    ClassListOutput(
                        target: analysis.target,
                        sliceIndex: analysis.sliceIndex,
                        architecture: analysis.architecture,
                        backend: analysis.backend,
                        warnings: analysis.warnings,
                        classes: analysis.metadata.classes.map(ObjectiveCClassSummary.init)
                    )
                )
            }
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func methods(path: String, className: String) {
        do {
            try InputResolver().withResolvedTarget(at: URL(filePath: path)) { target in
                let analysis = try ObjectiveCAnalyzer().analyze(target)
                guard
                    let objectiveCClass = analysis.metadata.classes.first(where: {
                        $0.name == className
                    })
                else {
                    throw CLIError("Objective-C class was not found: \(className)")
                }
                try writeJSON(
                    MethodListOutput(
                        target: analysis.target,
                        sliceIndex: analysis.sliceIndex,
                        architecture: analysis.architecture,
                        backend: analysis.backend,
                        warnings: analysis.warnings,
                        className: objectiveCClass.name,
                        instanceMethods: objectiveCClass.instanceMethods,
                        classMethods: objectiveCClass.classMethods
                    )
                )
            }
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func patchability(path: String, json: Bool) {
        do {
            try InputResolver().withResolvedTarget(at: URL(filePath: path)) { target in
                let analysis = try ObjectiveCAnalyzer().analyze(target)
                let output = PatchabilityCommandOutput(
                    target: analysis.target,
                    sliceIndex: analysis.sliceIndex,
                    architecture: analysis.architecture,
                    backend: analysis.backend,
                    warnings: analysis.warnings,
                    report: ObjectiveCPatchabilityAnalyzer.report(for: analysis.metadata)
                )
                if json {
                    try writeJSON(output)
                } else {
                    print(HumanPatchabilityReportFormatter.render(output), terminator: "")
                }
            }
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func validateProject(projectPath: String, targetPath: String?) {
        do {
            let project = try readProject(at: URL(filePath: projectPath))
            let report: PatchProjectValidationReport
            if let targetPath {
                report = try InputResolver().withResolvedTarget(
                    at: URL(filePath: targetPath)
                ) { target in
                    let sliceIndex = try AnalyzedPatchProjectValidator.selectedSliceIndex(
                        for: project,
                        in: target
                    )
                    let analysis = try ObjectiveCAnalyzer().analyze(
                        target,
                        sliceIndex: sliceIndex
                    )
                    return try AnalyzedPatchProjectValidator.validate(
                        project,
                        against: analysis
                    )
                }
            } else {
                let structural = PatchProjectValidator.validate(project)
                report = PatchProjectValidationReport(
                    errors: structural.errors,
                    warnings: structural.warnings + [
                        PatchProjectValidationIssue(
                            code: .targetNotAnalyzed,
                            message:
                                "No target was supplied; class, selector, slice, and current type encoding were not checked."
                        )
                    ]
                )
            }

            try writeJSON(report)
            if !report.isValid { exit(EXIT_FAILURE) }
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func readProject(at url: URL) throws -> PatchProject {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data =
            try handle.read(upToCount: PatchProjectCodec.maximumProjectBytes + 1) ?? Data()
        return try PatchProjectCodec.decode(data)
    }

    private static func generate(projectPath: String, outputPath: String) {
        do {
            let project = try readProject(at: URL(filePath: projectPath))
            let bundle = try ObjectiveCSourceGenerator().generate(project)
            let outputDirectory = URL(filePath: outputPath).standardizedFileURL
            let writtenURLs = try GeneratedSourceWriter.write(bundle, to: outputDirectory)
            try writeJSON(
                GenerateOutput(
                    projectPath: URL(filePath: projectPath).standardizedFileURL.path,
                    outputDirectory: outputDirectory.path,
                    files: writtenURLs.map(\.path)
                )
            )
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func build(
        projectPath: String,
        outputPath: String,
        architectureMode: PatchArchitectureMode?
    ) {
        do {
            let project = try readProject(at: URL(filePath: projectPath))
            let record = try PatchDylibBuilder().build(
                project,
                outputDirectory: URL(filePath: outputPath),
                architectureMode: architectureMode
            )
            try writeJSON(record)
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func parseBuildOptions(_ arguments: [String]) -> BuildOptions? {
        guard arguments.count == 4 || arguments.count == 6 else { return nil }
        var outputPath: String?
        var architectureMode: PatchArchitectureMode?
        var index = 2
        while index < arguments.count {
            let flag = arguments[index]
            let value = arguments[index + 1]
            switch flag {
            case "--output" where outputPath == nil:
                outputPath = value
            case "--arch" where architectureMode == nil:
                architectureMode = PatchArchitectureMode(rawValue: value)
                if architectureMode == nil { return nil }
            default:
                return nil
            }
            index += 2
        }
        guard let outputPath else { return nil }
        return BuildOptions(outputPath: outputPath, architectureMode: architectureMode)
    }

    private static func verify(
        dylibPath: String,
        targetPath: String?,
        json: Bool
    ) {
        do {
            let dylibURL = URL(filePath: dylibPath)
            let report: DylibVerificationReport
            if let targetPath {
                report = try InputResolver().withResolvedTarget(
                    at: URL(filePath: targetPath)
                ) { target in
                    let targetInspection = try MachOInspector().inspect(target)
                    return try LiveContainerVerifier().verify(
                        dylibURL: dylibURL,
                        targetInspection: targetInspection
                    )
                }
            } else {
                report = try LiveContainerVerifier().verify(dylibURL: dylibURL)
            }

            if json {
                try writeJSON(report)
            } else {
                print(HumanVerificationReportFormatter.render(report), terminator: "")
            }
            if !report.isReadyForLiveContainerTesting { exit(EXIT_FAILURE) }
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func parseVerifyOptions(_ arguments: [String]) -> VerifyOptions? {
        guard arguments.count >= 2 else { return nil }
        var targetPath: String?
        var json = false
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--json" where !json:
                json = true
                index += 1
            case "--target" where targetPath == nil && index + 1 < arguments.count:
                targetPath = arguments[index + 1]
                index += 2
            default:
                return nil
            }
        }
        return VerifyOptions(targetPath: targetPath, json: json)
    }
}

private struct ClassListOutput: Encodable {
    let target: ResolvedTarget
    let sliceIndex: Int
    let architecture: MachOArchitecture
    let backend: ObjectiveCAnalyzerBackend
    let warnings: [String]
    let classes: [ObjectiveCClassSummary]
}

private struct ObjectiveCClassSummary: Encodable {
    let name: String
    let superclassName: String?
    let imageName: String?
    let isLikelyAppDefined: Bool
    let isObjectiveCVisibleSwift: Bool
    let instanceMethodCount: Int
    let classMethodCount: Int
    let propertyCount: Int
    let ivarCount: Int
    let protocols: [String]

    init(_ objectiveCClass: ObjectiveCClass) {
        name = objectiveCClass.name
        superclassName = objectiveCClass.superclassName
        imageName = objectiveCClass.imageName
        isLikelyAppDefined = objectiveCClass.isLikelyAppDefined
        isObjectiveCVisibleSwift = objectiveCClass.isObjectiveCVisibleSwift
        instanceMethodCount = objectiveCClass.instanceMethods.count
        classMethodCount = objectiveCClass.classMethods.count
        propertyCount = objectiveCClass.properties.count
        ivarCount = objectiveCClass.ivars.count
        protocols = objectiveCClass.protocols
    }
}

private struct MethodListOutput: Encodable {
    let target: ResolvedTarget
    let sliceIndex: Int
    let architecture: MachOArchitecture
    let backend: ObjectiveCAnalyzerBackend
    let warnings: [String]
    let className: String
    let instanceMethods: [ObjectiveCMethod]
    let classMethods: [ObjectiveCMethod]
}

private struct PatchabilityCommandOutput: Encodable {
    let target: ResolvedTarget
    let sliceIndex: Int
    let architecture: MachOArchitecture
    let backend: ObjectiveCAnalyzerBackend
    let warnings: [String]
    let report: ObjectiveCPatchabilityReport
}

private enum HumanPatchabilityReportFormatter {
    static func render(_ output: PatchabilityCommandOutput) -> String {
        let summary = output.report.summary
        var lines = [
            "Patchability: \(output.target.executableName)",
            "Architecture: \(output.architecture.rawValue) (slice \(output.sliceIndex))",
            "Metadata backend: \(output.backend.rawValue)",
            "Method declarations: \(summary.methodCount)",
            "Available in editor: \(summary.patchableClassMethodCount)",
            "Additional patchable category declarations: \(summary.patchableCategoryMethodCount)",
            "Unavailable declarations: \(summary.unavailableMethodCount)",
        ]

        if !summary.issueCounts.isEmpty {
            lines.append("")
            lines.append("Unavailable reason occurrences:")
            lines.append(
                contentsOf: summary.issueCounts.map {
                    "  \($0.count)  \($0.code.displayName)"
                })
        }

        if !summary.unsupportedTypeCounts.isEmpty {
            lines.append("")
            lines.append("Unsupported ABI types:")
            lines.append(
                contentsOf: summary.unsupportedTypeCounts.prefix(15).map {
                    "  \($0.count)  \(roleLabel($0.role)) \($0.typeKind.rawValue) (\($0.typeEncoding))"
                })
        }

        if !output.warnings.isEmpty {
            lines.append("")
            lines.append("Analyzer warnings:")
            lines.append(contentsOf: output.warnings.map { "  - \($0)" })
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func roleLabel(_ role: ObjectiveCUnsupportedTypeRole) -> String {
        switch role {
        case .returnValue:
            "return"
        case .argument:
            "argument"
        }
    }
}

private struct CLIError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct GenerateOutput: Encodable {
    let projectPath: String
    let outputDirectory: String
    let files: [String]
}

private struct ArchitectureCommandOutput: Encodable {
    let target: ResolvedTarget
    let report: TargetArchitectureReport
}

private struct BuildOptions {
    let outputPath: String
    let architectureMode: PatchArchitectureMode?
}

private struct VerifyOptions {
    let targetPath: String?
    let json: Bool
}
