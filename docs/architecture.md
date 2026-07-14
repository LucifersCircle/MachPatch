# Architecture

MachPatch uses a modular Swift package so command-line and future SwiftUI frontends can share
the same implementation. Core libraries never depend on a user-interface target.

## Modules

| Module | Responsibility |
| --- | --- |
| `MachPatchCore` | Stable shared models, errors, versioning, and project data |
| `MachPatchAnalyzer` | Input resolution, Mach-O inspection, and metadata normalization |
| `MachPatchGenerator` | Deterministic Objective-C runtime source generation |
| `MachPatchBuilder` | Xcode toolchain discovery and dylib compilation |
| `MachPatchVerifier` | Mach-O output and LiveContainer compatibility checks |
| `MachPatchPackager` | Dylib and optional interoperability exports |
| `MachPatchCLI` | Argument parsing and presentation for the shared library APIs |

The intended dependency flow is:

```text
MachPatchCLI -> MachPatchCore
MachPatchAnalyzer -> MachPatchCore
MachPatchGenerator -> MachPatchCore
MachPatchBuilder -> MachPatchGenerator + MachPatchCore
MachPatchVerifier -> MachPatchAnalyzer + MachPatchCore
MachPatchPackager -> MachPatchBuilder + MachPatchVerifier + MachPatchCore
```

The CLI will add direct dependencies on feature modules as their commands are implemented.

## Design constraints

- Report unknown architecture and ABI values explicitly; never silently guess.
- Keep parsed Mach-O facts separate from architecture-selection policy.
- Use `Process` with argument arrays for external tools; never construct shell commands from
  input paths.
- Never execute content extracted from an IPA.
- Keep generated patches free of Theos, Logos, Substrate, ElleKit, and jailbreak paths.
- Keep models `Codable` and `Sendable` at analyzer and frontend boundaries.
- Do not begin the SwiftUI application until the CLI produces and verifies a working arm64
  dylib.

## Initial milestones

1. Bootstrap the package, CLI shell, tests, CI, and documentation.
2. Resolve IPA, `.app`, and direct Mach-O inputs to an executable and hash.
3. Inspect thin and fat Mach-O slices, platforms, deployment versions, encryption, and linked
   libraries.

Objective-C metadata extraction begins only after all three milestones are independently tested.
