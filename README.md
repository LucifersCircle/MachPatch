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

## Inspect Mach-O metadata

`inspect` resolves the input and parses every thin or fat Mach-O slice without relying on `lipo`
or `otool`:

```bash
.build/debug/machpatch inspect "/path/to/Fixture.ipa" --json
```

The JSON report includes:

- raw CPU type, subtype, subtype base, and capability bits;
- normalized architecture without collapsing unknown subtypes;
- iPhoneOS versus iPhone Simulator platform metadata;
- minimum OS and SDK versions;
- `LC_ENCRYPTION_INFO` or `LC_ENCRYPTION_INFO_64` values;
- file type, endianness, slice offset, and slice size;
- dylib install name and strong, weak, re-exported, upward, or lazy dependencies.

For example, an ordinary decrypted device executable reports facts such as:

```json
{
  "architecture": "arm64",
  "cpuSubtype": 0,
  "encrypted": false,
  "encryptionCryptID": 0,
  "minimumOSVersion": "15.6",
  "platform": "iPhoneOS",
  "platformValue": 2,
  "sdkVersion": "26.0"
}
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

Safe input resolution and native thin/fat Mach-O inspection are implemented. Objective-C metadata
extraction and the macOS interface are intentionally deferred until the remaining command-line
pipeline is reliable.
