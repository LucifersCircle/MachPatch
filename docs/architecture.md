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

The CLI depends directly on `MachPatchAnalyzer` and `MachPatchCore`; later commands will add the
remaining feature modules as their APIs become available.

## Input resolution

`InputResolver.withResolvedTarget` owns the lifetime of temporary IPA contents. Resolution uses
this flow:

```text
Validate input kind
  -> create a private mode-0700 workspace
  -> copy the IPA to a stable local snapshot
  -> validate ZIP and ZIP64 entry metadata
  -> reject traversal, absolute paths, and symbolic links
  -> extract with /usr/bin/ditto using a Process argument array
  -> locate the single Payload/*.app bundle
  -> parse Info.plist without executing bundle content
  -> verify the resolved file has a Mach-O magic value
  -> stream its SHA-256
  -> remove the workspace when the scoped operation exits
```

The private snapshot prevents the source IPA from changing between validation and extraction.
The current ZIP validator supports bounded single-disk archives, including ZIP64 size metadata on
individual entries. Multi-disk archives, encrypted ZIP entries, unsafe paths, special Unix file
types, and unreasonably large expanded archives are rejected explicitly.

## Mach-O inspection

`MachOInspector` is an internal bounds-checked reader for the facts needed before Objective-C
metadata extraction. It recognizes thin 32/64-bit headers and 32/64-bit fat containers in both
byte orders. Fat table CPU values are checked against each enclosed thin header, slice ranges may
not overlap, and load-command counts and byte ranges are bounded before parsing.

The reader currently normalizes:

- known CPU types and subtype bases while preserving raw signed subtype and capability bits;
- file type, byte order, and 32/64-bit status;
- `LC_BUILD_VERSION` and legacy version-minimum commands;
- device, simulator, Catalyst, and other known Apple platform values;
- 32/64-bit encryption commands and `cryptid`;
- dylib identity and load, weak, re-export, upward, and lazy dependencies.

Unknown CPU subtypes and platform values remain `unknown` with their raw numeric fields intact.
The parser reports these facts only. Architecture-selection policy belongs in the builder
layer and must not be added to `MachOInspector`.

## Objective-C metadata extraction

`ObjectiveCAnalyzer` exposes normalized `Codable` and `Sendable` models that do not expose a
backend's native object model. It rejects encrypted slices, invokes providers in priority order,
and records unavailable or failed providers as warnings whenever a later provider succeeds.

The provider chain is:

```text
Bundled Python helper -> LIEF Extended Objective-C API
                     -> xcrun otool fallback
                     -> normalized ObjectiveCMetadata
```

The LIEF helper is a replaceable proof-of-concept boundary. It produces JSON internally and is
available only when the active `python3` environment contains LIEF Extended Objective-C support.
The ordinary LIEF package does not provide that Extended API.

The development fallback parses Apple's `otool -ov` output. Some chained-fixup binaries print a
selector-reference address instead of a selector at each method record. In that case the provider
also reads `__objc_methname` and the `__objc_selrefs` sections, then resolves only exact pointer
relationships. Unresolved method references fail extraction rather than merging selectors by a
global name list. Classes, methods, properties, ivars, protocols, and categories are normalized,
sorted, and assigned deterministic IDs at the shared boundary.

`isLikelyAppDefined` is intentionally heuristic. It currently means metadata came from the main
executable and the class name did not match a small known third-party SDK marker list. It must
never be presented as conclusive first-party ownership.

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

## Completed milestones

1. Bootstrap the package, CLI shell, tests, CI, and documentation.
2. Resolve IPA, `.app`, and direct Mach-O inputs to an executable and hash.
3. Inspect thin and fat Mach-O slices, platforms, deployment versions, encryption, and linked
   libraries.
4. Extract and normalize Objective-C classes, methods, properties, ivars, protocols, and
   categories behind a replaceable provider boundary.
