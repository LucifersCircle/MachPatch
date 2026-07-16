# Architecture

MachPatch uses a modular Swift package so command-line and SwiftUI frontends can share
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
MachPatchBuilder -> MachPatchAnalyzer + MachPatchGenerator + MachPatchCore
MachPatchVerifier -> MachPatchAnalyzer + MachPatchCore
MachPatchPackager -> MachPatchBuilder + MachPatchVerifier + MachPatchCore
MachPatchApp -> shared analysis + generation + build + verification + packaging modules
```

The CLI depends directly on the analysis, builder, core, generator, and verifier modules. The app
also consumes the packager to present verified dylib, reproducible source-archive, and Debian
package exports without duplicating archive or policy logic in SwiftUI.

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
  -> resolve the host executable and enumerate embedded framework/extension bundles
  -> validate declared executable names and reject symbolic links
  -> verify every resolved file has a Mach-O magic value
  -> stream an independent SHA-256 for every image
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
records unavailable optional providers as notices, and preserves actual provider extraction
failures as warnings whenever a later provider succeeds.

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

Each analysis records its selected image explicitly, including kind, relative path, bundle
metadata, executable name, and SHA-256. `isLikelyAppDefined` remains a separate class-name
heuristic based on a small known third-party SDK marker list. It must never be presented as
conclusive first-party ownership or confused with the image that supplied the metadata.

`ObjectiveCMethodCatalog` canonicalizes class and category declarations by runtime class, method
kind, and selector. Equal nonempty encodings share one browser and validation record while
preserving every declaration origin. Conflicting encodings are never guessed: the method remains
visible with a blocking diagnostic. Category owners that have no class declaration in the current
image become explicit category-only runtime targets in the app and CLI. Property metadata is
linked only to getter/setter selectors that the catalog actually contains, including custom
runtime accessor attributes.

## Patch schema and type decoding

`MachPatchCore` owns the versioned project model, deterministic JSON codec, Objective-C type
decoder, and target-independent validation. This lets the CLI, future GUI, generator, and verifier
share one action-compatibility decision.

The type decoder separates type tokens from method frame sizes and argument offsets. It recognizes
unsupported ABI shapes so validation can reject them explicitly instead of misclassifying them.
`MachPatchAnalyzer` adds target-backed validation by selecting the exact architecture/subtype and
checking the current class, selector, method kind, and raw encoding.

`ObjectiveCPatchabilityAnalyzer` applies that shared compatibility policy to every class and
category method declaration. Its deterministic report distinguishes editor-available class
declarations from compatible category opportunities, records stable unavailable reason codes, and
ranks exact unsupported return/argument encodings. The CLI and SwiftUI target summary consume the
same report model; neither frontend maintains a separate list of supported signatures.

## Objective-C source generation

`MachPatchGenerator` converts a structurally valid version 1 project into one deterministic
`MachPatchGenerated.m` file. Generation has no analyzer or filesystem dependency. A separate
writer performs bounded-path, symlink-resistant, atomic export to the user-selected directory.

For every enabled patch, the generator maps the decoded signature to exact C parameter and return
types, scopes sanitized identifiers by project index, emits the replacement, and adds a runtime
installer. Original IMP storage is generated only for actions that call through. Object-returning
selectors in retained method families receive the appropriate Clang ownership attribute.

Scalar generation preserves the analyzed ABI rather than source typedef names: `f` emits `float`
and `d` emits `double`, including 64-bit `CGFloat` encodings. Finite numeric values are rendered as
locale-independent C literals, and variadic logging uses explicit promotions. Class and selector
values use `objc_getClass`, `sel_registerName`, and typed `Nil`/`NULL` expressions instead of raw
addresses.

Complex ABI support is deliberately tiered. Block arguments are represented as opaque Objective-C
objects and pointer arguments as `void *`; only call-through actions may use them, logging exposes
addresses only, and generated presets never dereference or invoke either value. `CGPoint`,
`CGSize`, `CGRect`, and `NSRange` are recognized only when their names and complete 64-bit layouts
match, then emitted as exact SDK C types. Arbitrary composites and pointer/block returns remain
explicitly unsupported.

Installers use exact `method_getTypeEncoding` comparisons, `class_getInstanceMethod` for instance
methods, and the same lookup on `object_getClass(cls)` for class methods. State transitions are
pending, installed, or permanently failed. The constructor tries once immediately, then performs
bounded main-queue retries after 1, 3, and 8 seconds.

## Dylib building

`MachPatchBuilder` discovers the active developer directory, Clang, and iPhoneOS SDK through
direct `xcode-select` and `xcrun` process invocations. Discovery records the Xcode, compiler, and
SDK versions. Compilation then launches the resolved Clang executable directly with an argument
array; user-controlled paths are never interpolated into a shell command.

`ArchitectureResolver` keeps policy separate from parsed Mach-O facts. Automatic mode follows the
project's exact selected slice, explicit modes cannot relabel an incompatible target, and legacy
unversioned arm64e is distinct from versioned pointer-authentication ABI output. Simulator and
unsupported CPU families are reported but never selected.

Before compiling project source, the builder performs a minimal thin-dylib probe for every
requested architecture and parses its CPU subtype, platform, and deployment target natively.
arm64e probe metadata must exactly match a selected arm64e target subtype. Each compiled thin
output is parsed again and compared with its probe. Universal builds retain separate arm64 and
arm64e products, compare their externally defined symbol sets with the discovered `nm`, then use
the discovered `lipo` only after both validate; the merged slices are parsed and compared with
their thin inputs.

Generated products use `@rpath/<outputName>.dylib`. Successful builds persist build-record format
2 with the resolution reason, capability probes, thin-slice metadata, compiler invocations, and
optional merge invocation. Failed compilation, validation, or merging removes partial products.
Existing symbolic-link destinations and directory collisions are refused.

## LiveContainer compatibility verification

`LiveContainerVerifier` consumes the same native `MachOInspector` facts used by the builder. It
requires device dynamic-library slices, validates CPU subtype/platform/deployment/install-name
metadata, and cross-checks the native architecture list with the discovered Xcode `lipo`. The
discovered `nm` is run once per slice architecture so undefined symbols are not silently limited
to the host-preferred slice.

Dependency policy is applied to directly parsed load commands. Apple system libraries are
accepted. Relative third-party dependencies are accepted only when the referenced regular file is
contained beside the export without traversal or symbolic-link components. Jailbreak dependencies
and unsupported external paths block verification. A bounded native ASCII scan separately catches
embedded `/var/jb`, rootless bootstrap, Substrate, ElleKit, libhooker, and PreferenceLoader
references that are not load commands.

The report model is `Codable` and records raw slices, target slices, dependency and symbol
classifications, tool executions, individual pass/warn/fail checks, and an explicit final result.
The CLI renders it as text by default or stable JSON with `--json`, and returns nonzero when any
blocking check fails.

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

0. Bootstrap the package, CLI shell, tests, CI, and documentation.
1. Resolve IPA, `.app`, and direct Mach-O inputs to an executable and hash.
2. Inspect thin and fat Mach-O slices, platforms, deployment versions, encryption, and linked
   libraries.
3. Extract and normalize Objective-C classes, methods, properties, ivars, protocols, and
   categories behind a replaceable provider boundary.
4. Round-trip patch schema version 1, decode Objective-C method signatures, and validate actions
   structurally or against a current target.
5. Generate deterministic, snapshot-tested native Objective-C runtime patch source with bounded
   late-class retries.
6. Discover the selected Xcode/iPhoneOS toolchain and build clean ordinary arm64 dylibs with
   recorded commands and diagnostics.
7. Resolve automatic/explicit architectures, distinguish legacy and versioned arm64e, probe the
   selected toolchain, compare generated CPU metadata, and merge only validated universal slices.
8. Verify LiveContainer compatibility with native facts, per-slice Apple-tool cross-checks,
   dependency/symbol/path policy, target comparison, text/JSON reports, and blocking status.
9. Confirm constructor, immediate, original-result, late-loaded, and failed-patch behavior through
   LiveContainer without a jailbreak-specific dependency.
10. Provide the full SwiftUI import, browser, patch editor, project, build, verification, and dylib
    export workflow.
11. Export deterministic source archives and ordinary-arm64 Debian archives while keeping the
    plain dylib primary. Theos and Frida outputs are deferred by product scope.
12. Add composable advanced behavior, Foundation object presets, expert Objective-C snippets,
    target-aware private patch storage, import/export workflows, and native macOS File commands.

Post-version-0.1 coverage and release work is tracked in
[implementation-roadmap.md](implementation-roadmap.md).
