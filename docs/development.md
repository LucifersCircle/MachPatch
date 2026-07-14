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
