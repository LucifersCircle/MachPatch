# MachPatch

MachPatch is an Apple Silicon macOS tool for inspecting decrypted iOS applications and
building self-contained Objective-C runtime patch dylibs. The project is under active
development; the current package contains the foundational command-line and library modules.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xcode with the iPhoneOS SDK
- Swift 6.0 or later

## Build and test

```bash
swift build
swift test
.build/debug/machpatch --help
.build/debug/machpatch --version
```

## Development tools

The repository includes configuration for `swift-format` and SwiftLint. When those tools are
installed locally, run:

```bash
swift-format lint --recursive --strict Sources Tests
swiftlint lint --strict
```

## Architecture

The package separates analysis, generation, building, verification, and packaging from its
command-line frontend. See [docs/architecture.md](docs/architecture.md) for module boundaries
and implementation constraints.

## Project status

The first implementation phase covers safe IPA and app resolution followed by internal Mach-O
inspection. Objective-C metadata extraction and the macOS interface are intentionally deferred
until the command-line inspection pipeline is reliable.
