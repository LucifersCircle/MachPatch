import Darwin
import Foundation
import MachPatchAnalyzer
import MachPatchBuilder
import MachPatchCore
import MachPatchGenerator

@main
struct MachPatchCommand {
    private static let help = """
        OVERVIEW: Inspect iOS applications and build native runtime patches.

        USAGE: machpatch <command> [arguments]

        COMMANDS:
          resolve <path>         Resolve an IPA, .app, or Mach-O executable.
          inspect <path> [--json]
                                 Inspect every Mach-O slice and load command.
          classes <path> [--json]
                                 List normalized Objective-C classes.
          methods <path> <class> [--json]
                                 List methods declared by an Objective-C class.
          validate-project <project> [--target <path>]
                                 Validate a patch project, optionally against a target.
          generate <project> --output <directory>
                                 Generate deterministic Objective-C patch source.
          build <project> --output <directory>
                                 Build an ordinary arm64 iPhoneOS patch dylib.

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
            guard arguments.count == 4, arguments[2] == "--output" else {
                writeError("Usage: machpatch build <project.json> --output <directory>\n")
                exit(EX_USAGE)
            }
            build(projectPath: arguments[1], outputPath: arguments[3])
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

    private static func build(projectPath: String, outputPath: String) {
        do {
            let project = try readProject(at: URL(filePath: projectPath))
            let record = try PatchDylibBuilder().build(
                project,
                outputDirectory: URL(filePath: outputPath)
            )
            try writeJSON(record)
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
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
