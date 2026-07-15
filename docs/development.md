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
