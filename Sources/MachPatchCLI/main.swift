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
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                var data = try encoder.encode(target)
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            }
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }
}
