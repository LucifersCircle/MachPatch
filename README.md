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

## Inspect Objective-C metadata

`classes` emits stable JSON summaries for Objective-C classes in the selected executable slice:

```bash
.build/debug/machpatch classes "/path/to/Fixture.ipa"
```

Each summary includes its superclass, declared method/property/ivar counts, adopted protocols,
Objective-C-visible Swift status, and the explicitly heuristic `isLikelyAppDefined` flag.

`methods` returns the instance and class methods declared by one exact class name, including raw
Objective-C type encodings and implementation addresses when the analyzer can recover them:

```bash
.build/debug/machpatch methods "/path/to/Fixture.ipa" FixtureViewController
```

The analyzer first probes the bundled Python bridge for LIEF Extended Objective-C support. When
that optional capability is unavailable, it records the reason in `warnings` and falls back to
Apple's `xcrun otool`. The fallback resolves selector references against the executable's method
name and selector-reference sections; it never assigns a global selector to a class without an
address relationship.

Both commands reject an encrypted slice before metadata extraction. `--json` is accepted for
script compatibility; JSON is the only output format during the CLI-first implementation.

## Validate a patch project

Patch projects are versioned JSON with immutable target identity, build settings, method patches,
and type-safe actions. Validate the schema and action/type compatibility with:

```bash
.build/debug/machpatch validate-project Examples/ExamplePatch.json
```

Add a current IPA, app, or executable to verify its exact class, selector, method kind, selected
slice, and raw type encoding:

```bash
.build/debug/machpatch validate-project patch.json --target "/path/to/Fixture.ipa"
```

See [docs/patch-format.md](docs/patch-format.md) for the version 1 schema, supported actions, and
MVP type rules.

## Generate Objective-C source

Generate a self-contained native runtime patch source file from a valid project:

```bash
.build/debug/machpatch generate Examples/ExamplePatch.json --output Generated
```

The command writes `Generated/MachPatchGenerated.m` atomically and prints a JSON summary of the
created file. Generated source uses Foundation and Apple's Objective-C runtime directly—there are
no Theos, Logos, Substrate, ElleKit, or jailbreak-path dependencies.

Each enabled patch receives a deterministic, index-scoped C identifier, an ABI-matched
replacement function, an exact runtime type-encoding guard, and an idempotent installation
function. Class methods are installed on the metaclass. Actions that preserve behavior store a
typed original IMP; direct-return actions do not. Missing classes are retried on the main queue at
1, 3, and 8 seconds before being marked failed.

## Build a device dylib

Inspect a target's device slices, then build with the active Xcode iPhoneOS toolchain:

```bash
.build/debug/machpatch architectures "/path/to/Target.ipa"
.build/debug/machpatch build Examples/ExamplePatch.json \
  --output "Build Output" --arch automatic
```

The command writes `MachPatchGenerated.m`, the configured `<outputName>.dylib`, and
`MachPatchBuild.json`. The JSON build record captures the selected developer directory, Xcode and
Clang versions, iPhoneOS SDK path/version, exact compiler executable and argument array, standard
output/error, exit status, duration, deployment target, architecture decision, capability probes,
validated CPU subtype, and `@rpath` install name.

`automatic` follows the project's recorded slice: ordinary arm64 stays arm64, while only a
versioned modern arm64e target can select arm64e. Explicit modes cannot relabel an incompatible
target. `universal` probes and compiles arm64 and arm64e separately, validates both thin outputs,
and invokes `lipo` only after both pass. Legacy unversioned arm64e and simulator slices are blocked
with diagnostics. Rebuilding removes stale products first, and failures leave no partial dylib.
Every compiler and merge process uses argument arrays without a shell.

## Verify LiveContainer compatibility

Audit a built dylib by itself or compare it with the current IPA, app, or executable:

```bash
.build/debug/machpatch verify "Build Output/ExamplePatch.dylib"
.build/debug/machpatch verify "Build Output/ExamplePatch.dylib" \
  --target "/path/to/Target.ipa"
.build/debug/machpatch verify "Build Output/ExamplePatch.dylib" \
  --target "/path/to/Target.ipa" --json
```

Human-readable output is the default. `--json` emits the complete format-versioned report for
automation and the future GUI. A blocking check returns a nonzero exit status.

The verifier parses every Mach-O slice natively and cross-checks the architecture list with
`lipo`. It requires an iPhoneOS dynamic library, supported arm64 or versioned arm64e CPU metadata,
the expected `@rpath/<filename>` identity, and a declared deployment target. It audits native
load commands, runs `nm` separately for every slice, classifies unresolved symbols, scans embedded
strings for jailbreak bootstrap paths, and compares architecture/subtype and deployment metadata
with the supplied target. Simulator output, legacy arm64e, Substrate/ElleKit/libhooker paths,
unbundled third-party dependencies, development-machine install names, and incompatible targets
are blocking failures.

See [docs/livecontainer.md](docs/livecontainer.md) for the verification policy, device import and
test workflow, Milestone 9 acceptance record, and known loader limitations.

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

Safe input resolution, native thin/fat Mach-O inspection, normalized Objective-C metadata
extraction, patch schema/type validation, native Objective-C source generation, device dylib
building, architecture resolution, modern arm64e capability probing, and validated universal
output are implemented. LiveContainer compatibility verification now produces human-readable and
JSON reports with blocking exit status. Real LiveContainer loading is Milestone 9. The full
SwiftUI interface is Milestone 10, after successful LiveContainer testing.
