import Darwin
import Foundation
import MachPatchAnalyzer
import MachPatchCore

@main
struct MachPatchCommand {
    private static let help = """
        OVERVIEW: Inspect iOS applications and build native runtime patches.

        USAGE: machpatch <command> [arguments]

        COMMANDS:
          resolve <path>         Resolve an IPA, .app, or Mach-O executable.
          inspect <path> [--json]
                                 Inspect every Mach-O slice and load command.

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
}
