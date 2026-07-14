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

## Resolve an input

`resolve` accepts a decrypted IPA, an iOS `.app` directory, or a direct Mach-O executable:

```bash
.build/debug/machpatch resolve "/path/with spaces/Fixture.ipa"
```

It prints stable JSON containing the bundle metadata, resolved executable path, and SHA-256:

```json
{
  "bundleIdentifier": "com.example.fixture",
  "displayName": "Fixture",
  "executableName": "Fixture",
  "executablePath": "/private/tmp/MachPatch-…/Extracted/Payload/Fixture.app/Fixture",
  "minimumOSVersion": "15.0",
  "sha256": "…",
  "sourcePath": "/path/with spaces/Fixture.ipa",
  "sourceType": "ipa",
  "supportedPlatforms": ["iPhoneOS"]
}
```

IPA paths in the JSON refer to a scoped temporary workspace. The resolver removes that workspace
immediately after the command finishes. Library clients use the scoped `withResolvedTarget` API
to inspect an extracted executable while it is available.

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

Safe IPA, app-bundle, and direct Mach-O resolution is implemented. Internal Mach-O inspection is
the next milestone. Objective-C metadata extraction and the macOS interface are intentionally
deferred until the command-line inspection pipeline is reliable.
