# MachPatch

MachPatch is an Apple Silicon macOS tool for inspecting decrypted iOS applications and
building self-contained Objective-C runtime patch dylibs through a native SwiftUI app and a
scriptable command-line interface.

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

Create a signed release `.app` bundle, including the production macOS icon, with:

```bash
Scripts/package-app.sh
open dist/MachPatch.app
```

Create the arm64 drag-to-install disk image used for GitHub releases with:

```bash
Scripts/create-release-dmg.sh dist 0.1.0
open dist/MachPatch-0.1.0-macOS-arm64.dmg
```

The **Release** GitHub Actions workflow can be run manually to prove the build and retain its DMG
as a workflow artifact. Pushing a tag matching the bundle version, such as `v0.1.0`, also creates a
GitHub Release with the DMG and SHA-256 attached directly.

Official MachPatch packages are ad-hoc signed and are not Apple-notarized. macOS Gatekeeper may
require explicit approval in **System Settings > Privacy & Security** before the first launch.
Download releases only from the official repository and verify the published SHA-256 checksum.
Do not disable Gatekeeper globally.

## Resolve an input

`resolve` accepts a decrypted IPA, an iOS `.app` directory, a `.framework` bundle, or a direct
Mach-O executable:

```bash
.build/debug/machpatch resolve "/path/with spaces/Fixture.ipa"
```

It prints stable JSON containing host metadata plus independently hashed inspectable images:

```json
{
  "bundleIdentifier": "com.example.fixture",
  "displayName": "Fixture",
  "executableName": "Fixture",
  "executablePath": "/private/tmp/MachPatch-…/Extracted/Payload/Fixture.app/Fixture",
  "minimumOSVersion": "15.0",
  "images": [
    {
      "kind": "mainExecutable",
      "relativePath": "Fixture",
      "executableName": "Fixture",
      "sha256": "…"
    },
    {
      "kind": "dynamicFramework",
      "relativePath": "Frameworks/FixtureKit.framework/FixtureKit",
      "executableName": "FixtureKit",
      "sha256": "…"
    }
  ],
  "sha256": "…",
  "sourcePath": "/path/with spaces/Fixture.ipa",
  "sourceType": "ipa",
  "supportedPlatforms": ["iPhoneOS"]
}
```

IPA paths in the JSON refer to a scoped temporary workspace. The resolver removes that workspace
immediately after the command finishes. Library clients use the scoped `withResolvedTarget` API
to inspect extracted images while they are available. App inputs enumerate the main executable,
embedded frameworks, supported app extensions, and frameworks nested inside those extensions
without executing bundle content. Unsafe or malformed embedded candidates are retained as
discovery diagnostics instead of hiding the valid host image.

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
Objective-C-visible Swift status, and the explicitly heuristic `isLikelyAppDefined` flag. The
output also lists category owners, including runtime classes that are not declared by the analyzed
executable itself.

`methods` returns the instance and class methods declared by one exact class name, including raw
Objective-C type encodings and implementation addresses when the analyzer can recover them:

```bash
.build/debug/machpatch methods "/path/to/Fixture.ipa" FixtureViewController
```

The class name may also be a category-only runtime target such as an Apple framework class. Class
and category declarations with the same selector are canonicalized by method kind and runtime
identity. Matching encodings become one method record with all declaration origins; conflicting
encodings remain visible but are blocked from patching.

The analyzer first probes the bundled Python bridge for LIEF Extended Objective-C support. When
that optional capability is unavailable, it records an informational notice and falls back to
Apple's `xcrun otool`. Provider extraction failures remain warnings. The fallback resolves selector
references against the executable's method name and selector-reference sections; it never assigns
a global selector to a class without an address relationship.

Both commands reject an encrypted slice before metadata extraction. `--json` is accepted for
script compatibility; JSON is the only output format during the CLI-first implementation.

## Measure patchability

`patchability` classifies every Objective-C method declaration using the same signature rules as
project validation and the patch editor:

```bash
.build/debug/machpatch patchability "/path/to/Fixture.ipa"
.build/debug/machpatch patchability "/path/to/Fixture.ipa" --json
```

Human-readable output summarizes declarations available in the editor, compatible category
declarations available under **Category Targets**, unavailable declarations, reason counts, and the most
common unsupported ABI types. `--json` emits the complete deterministic report, including every
class/category origin, selector, raw and decoded signature, compatible action list, and exact
unavailable issues. Counts describe metadata declarations; a class and category that declare the
same runtime selector are intentionally separate until category canonicalization is implemented.

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

The app's advanced patch editor can compose typed argument replacement, conditional results,
thread-safe invocation counters, before/after alert presets, and expert Objective-C snippets around
the primary action. It can also construct common Foundation object returns such as `NSNumber`,
string arrays/dictionaries, and `NSURL`. Finite `float` and `double` values work in returns,
arguments, conditions, logging, and original-result replacement. `Class` and `SEL` methods can
return validated runtime names or explicit `Nil`/`NULL`. Every option is validated against the
decoded method signature before source generation or building.

Opaque pointer and block arguments can now pass through to the original implementation, log only
their addresses, or be explicitly replaced/compared with `NULL`/`nil`; presets never dereference
pointers or invoke blocks. Exact 64-bit `CGPoint`, `CGSize`, `CGRect`, and `NSRange` layouts use
typed pass-through and field logging. Pointer/block returns and arbitrary structures remain
unavailable.

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
validated CPU subtype, and `@rpath` install name. Its provenance section records canonical SHA-256
digests for the host target, selected image, patch project, generated source, and final dylib. App
and packaging workflows append the final verification outcome and check counts to that same record.

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
automation and other frontends. A blocking check returns a nonzero exit status.

The verifier parses every Mach-O slice natively and cross-checks the architecture list with
`lipo`. It requires an iPhoneOS dynamic library, supported arm64 or versioned arm64e CPU metadata,
the expected `@rpath/<filename>` identity, and a declared deployment target. It audits native
load commands, runs `nm` separately for every slice, classifies unresolved symbols, scans embedded
strings for jailbreak bootstrap paths, and compares architecture/subtype and deployment metadata
with the supplied target. Simulator output, legacy arm64e, Substrate/ElleKit/libhooker paths,
unbundled third-party dependencies, development-machine install names, and incompatible targets
are blocking failures.

See [docs/livecontainer.md](docs/livecontainer.md) for the verification policy, device import and
test workflow, recorded device acceptance, and known loader limitations.

## Patch library

The SwiftUI app can save valid patch projects to its private library at
`~/Library/Application Support/MachPatch/Saved Patches`. **Save Patch** updates the matching
project in that library. **Load Patch** lists only projects relevant to the analyzed target: exact
executable matches and, for bundled apps, other builds with the same bundle identifier,
executable name, and selected slice. Normal compatibility validation still runs before loading.
**Delete Saved Patch** lists the entire private library and requires destructive confirmation.
**Import Patch…** and **Export Patch…** remain available for exchanging the same canonical JSON
format with other locations or users.

## Category targets and property accessors

The SwiftUI sidebar separates classes declared by the executable from category-only runtime
targets. Category names participate in global and per-class method search, and every method shows
its class/category declaration origins. Category patches use the owning runtime class and selector,
so they retain the same project schema and generated runtime installer as ordinary class methods.

Properties link to their declared getter and setter methods, including custom `G` and `S`
accessors. Read-only and missing accessors are identified inline. MachPatch never invents an
accessor signature when the binary metadata does not declare that method.

## Optional exports

The SwiftUI build workspace keeps the verified plain dylib as the primary LiveContainer output.
After a successful build it can also export:

- a reproducible source `.zip` containing canonical `patch.json`, deterministic
  `MachPatchGenerated.m`, target identity, and an executable Xcode/iPhoneOS `build.sh`; or
- an ordinary-arm64 `.deb` containing the dylib and a bundle-specific MobileSubstrate filter
  plist.

Debian export requires a verified ordinary arm64 build and a target bundle identifier. MachPatch
does not guess package architecture metadata for arm64e or universal outputs. Theos and Frida
exports are intentionally deferred; they are not required to build, inspect, or reproduce the
native runtime patch.

The same packagers are available from the CLI as a build-and-verify workflow:

```bash
.build/debug/machpatch package Examples/ExamplePatch.json \
  --format source --output "Package Output"
.build/debug/machpatch package Examples/ExamplePatch.json \
  --format deb --output "Package Output"
```

Add `--target /path/to/Target.ipa` to verify deployment and slice compatibility against the exact
recorded app image. `--arch` accepts the same modes as `build`. The command retains the generated
source, dylib, and verification-bearing `MachPatchBuild.json` beside the requested ZIP or Debian
package and prints their exact paths as JSON.

Use [docs/release-checklist.md](docs/release-checklist.md) to run and record the automated,
performance, macOS UI, and device gates for a release candidate.

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

## License

MachPatch is free software licensed under the
[GNU General Public License version 3 only](LICENSE). Modified versions distributed to others
remain covered by GPLv3.

The [MachPatch Generated Output Exception](GENERATED-OUTPUT-EXCEPTION) is an additional permission
under GPLv3 section 7. It allows generated source, dylibs, packages, projects, and related outputs
to be used and distributed under terms chosen by their creators, even when MachPatch emits code
from its own templates. The exception grants no rights in target applications, user-provided
inputs, or other third-party material.

## Project status

Safe input resolution, native Mach-O and Objective-C inspection, type-aware patch editing,
deterministic source generation, device dylib building, architecture resolution, LiveContainer
verification, runtime controls, release packaging, and the complete SwiftUI workflow are
implemented. Device acceptance covers immediate, original-call, late-loaded, category, framework,
and in-app-controlled patches. Reproducible source archives and ordinary-arm64 Debian packages are
available as optional outputs.

Public release readiness is governed by [docs/release-checklist.md](docs/release-checklist.md).
