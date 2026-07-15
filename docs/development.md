# Development

Run `swift build`, `swift test`, and the relevant CLI acceptance command at the end of every
milestone. Do not continue from a milestone with known test failures.

Fixture binaries must be purpose-built, redistributable test inputs and must never contain
third-party application code.

## Input-resolution acceptance checks

```bash
swift build
swift test
.build/debug/machpatch resolve /path/to/Fixture.ipa
.build/debug/machpatch resolve /path/to/Fixture.app
.build/debug/machpatch resolve /path/to/FixtureExecutable
```

A successful IPA result includes `sourceType`, bundle metadata, the executable name and temporary
path, and a lowercase 64-character SHA-256. The temporary `MachPatch-*` workspace must no longer
exist after the command returns. A matching standalone executable and IPA-contained executable
must report the same hash.

## Mach-O inspection acceptance checks

```bash
swift build
swift test
.build/debug/machpatch inspect /path/to/Fixture.ipa --json
xcrun lipo -archs /path/to/FixtureExecutable
xcrun vtool -show-build /path/to/FixtureExecutable
xcrun otool -l /path/to/FixtureExecutable
```

Compare the native report with the Apple tools during development, while keeping tests dependent
only on programmatically generated Mach-O headers. The report must enumerate every fat slice,
preserve raw CPU metadata, distinguish device and simulator platforms from explicit load-command
values, and return a nonzero status for malformed ranges or load commands.

## Objective-C metadata acceptance checks

Use only decrypted binaries that you are authorized to inspect. Keep proprietary fixtures outside
the repository and pass their absolute paths to the CLI:

```bash
swift build
swift test
.build/debug/machpatch classes /path/to/DecryptedExecutable
.build/debug/machpatch methods /path/to/DecryptedExecutable ExampleClass
xcrun otool -ov /path/to/DecryptedExecutable
xcrun dyld_info -objc /path/to/DecryptedExecutable
```

The class command must report its selected backend and any fallback warning. The method command
must preserve raw type encodings and separate instance methods from class methods. Compare a few
representative classes with `otool` and `dyld_info`; selector membership must be backed by the
class record or an exact selector-reference mapping.

LIEF Extended is optional. `Sources/MachPatchAnalyzer/Resources/lief_objc_analyzer.py --probe`
reports whether the active `python3` has the required Objective-C API. Ordinary LIEF installations
fall back cleanly to `otool`. If `dsdump` is installed separately, it may also be used as an
independent development comparison; it is not a runtime dependency or a test requirement.

## Patch-project validation acceptance checks

```bash
swift build
swift test
.build/debug/machpatch validate-project Examples/ExamplePatch.json
.build/debug/machpatch validate-project /path/to/patch.json --target /path/to/Target.ipa
```

The first command validates schema version, identity fields, UUIDs, duplicate targets, method
signature grammar, selector arity, integer widths, and action compatibility. It emits a
`targetNotAnalyzed` warning because no current binary was supplied.

The target-backed form must select the exact recorded architecture and raw CPU subtype. It then
checks the current executable identity, class, selector, instance/class kind, and raw type
encoding. Identity changes are warnings; an absent slice, class, method, wrong kind, changed
encoding, or incompatible ABI is an error and returns a nonzero status.

## Source-generation acceptance checks

```bash
swift build
swift test
.build/debug/machpatch generate Examples/ExamplePatch.json --output /tmp/MachPatchGenerated
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
  -fobjc-arc -fblocks -Wall -Wextra -Werror -fsyntax-only -x objective-c \
  /tmp/MachPatchGenerated/MachPatchGenerated.m
```

Generation must be byte-stable for the same project and must reject a project that fails schema or
action validation. Inspect the source to confirm that instance and class methods use the correct
runtime object, different classes cannot collide after identifier sanitization, exact raw type
encodings are checked before installation, and only call-through actions retain a typed original
IMP.

The test suite compiles a project covering every version 1 action and all supported argument ABI
types with host Clang warnings treated as errors. It also compares the example against a checked-in
source snapshot and verifies symlink-resistant atomic output behavior. The iPhoneOS syntax command
above is the milestone acceptance check; producing a linked dylib belongs to the builder milestone.

## arm64 builder acceptance checks

```bash
swift build
swift test
.build/debug/machpatch build Examples/ExamplePatch.json \
  --output "/tmp/MachPatch Builder Acceptance"
.build/debug/machpatch inspect \
  "/tmp/MachPatch Builder Acceptance/ExamplePatch.dylib" --json
xcrun lipo -archs "/tmp/MachPatch Builder Acceptance/ExamplePatch.dylib"
xcrun otool -D "/tmp/MachPatch Builder Acceptance/ExamplePatch.dylib"
xcrun otool -L "/tmp/MachPatch Builder Acceptance/ExamplePatch.dylib"
```

The native report and Apple tools must agree that the output is a single ordinary arm64
`dynamicLibrary` for `iPhoneOS`, uses the project deployment target, and has the install name
`@rpath/ExamplePatch.dylib`. Dependencies must be Apple system frameworks/libraries only; no
Substrate, ElleKit, libhooker, or jailbreak-bootstrap path may appear.

Run the same command twice to exercise clean rebuilding. `MachPatchBuild.json` must contain the
selected developer directory, Xcode/Clang/SDK versions, exact compiler argument array, captured
stdout/stderr, termination status, and duration. The unit suite simulates compiler failure and
requires diagnostics to surface while neither a stale nor partial dylib remains.

## Architecture-resolution acceptance checks

```bash
.build/debug/machpatch architectures /path/to/Target.ipa
.build/debug/machpatch build Examples/ExamplePatch.json \
  --output /tmp/MachPatch-arm64 --arch arm64
.build/debug/machpatch build Examples/ExamplePatch.json \
  --output /tmp/MachPatch-universal --arch universal
.build/debug/machpatch inspect /tmp/MachPatch-universal/ExamplePatch.dylib --json
xcrun lipo -detailed_info /tmp/MachPatch-universal/ExamplePatch.dylib
```

For a dedicated modern arm64e fixture project, also build with `--arch automatic` and confirm the
recorded raw CPU subtype equals the target subtype. Every requested slice must have a successful
capability probe before project compilation starts. Native inspection must report iPhoneOS,
matching deployment targets and install names, subtype `ARM64_ALL` for arm64, and a versioned
pointer-authentication subtype for arm64e. Universal output is valid only when both retained thin
slices export the same defined symbols and both fat slices agree with them. Legacy unversioned
arm64e fixtures and simulator targets must produce blocking diagnostics rather than fallback
output.

## LiveContainer-verifier acceptance checks

```bash
.build/debug/machpatch verify /path/to/ExamplePatch.dylib \
  --target /path/to/Target.ipa
.build/debug/machpatch verify /path/to/ExamplePatch.dylib \
  --target /path/to/Target.ipa --json
```

For a successful report, native parsing and `lipo` must agree on every architecture; every slice
must be an iPhoneOS dynamic library with a supported CPU subtype, deployment target, and exact
`@rpath/<filename>` identity. `nm` must run separately for every architecture. Directly parsed
dependencies must be Apple system libraries or safely included in the export, all unresolved
symbols must be classified, no jailbreak path marker may be embedded, and at least one slice must
match the current target.

The unit suite uses purpose-built Mach-O headers and scripted tool output to require blocking
reports for iOS Simulator binaries, mismatched CPU metadata, `/var/jb`, CydiaSubstrate,
development-machine install names, unexpected unresolved symbols, and native/`lipo` disagreement.
Run the command against a real Xcode-built thin and universal dylib as the final acceptance check.
The text report must be readable, the JSON report must include `formatVersion`, checks, raw facts,
tool executions, and `result`, and a blocking report must exit nonzero.

## Optional-export acceptance checks

```bash
swift test --filter MachPatchPackagerTests
```

The source-bundle tests require a valid deterministic ZIP containing canonical `patch.json`,
byte-identical generated source, target identity, and an executable build script. When Xcode and
the iPhoneOS SDK are installed, the suite runs that script and confirms it produces an arm64 dylib.

The Debian tests parse the `ar` and tar members directly and require `debian-binary`, `control.tar`,
and `data.tar`. The data archive must contain the expected dylib and bundle-specific
MobileSubstrate filter plist. When `dpkg-deb` is installed, the suite also requires it to accept
the generated package metadata. arm64e and universal `.deb` export remain blocked until their
package architecture metadata is explicitly defined.
