# LiveContainer export

The primary artifact is a plain, self-contained iPhoneOS dylib. Verification is a preflight audit;
it cannot prove that a particular LiveContainer version will load a dylib or that a runtime patch
will find its class. Those behaviors are exercised on-device in Milestone 9.

## Run the verifier

```bash
.build/debug/machpatch verify Build/ExamplePatch.dylib \
  --target /path/to/Target.ipa
```

The default report is designed for a person. Add `--json` for a format-versioned report suitable
for the SwiftUI application or other automation. A report containing any failed check exits
nonzero. Warnings, such as omitting `--target`, do not block a load-only test.

## Blocking policy

Every output slice must:

- be an iPhoneOS dynamic library, never an iOS Simulator library;
- use ordinary arm64 or a versioned modern arm64e CPU subtype;
- declare a minimum iOS version;
- identify itself as `@rpath/<output filename>`;
- contain only Apple system dependencies or explicitly adjacent bundled dependencies;
- avoid jailbreak-only dependencies and embedded bootstrap paths;
- contain no unexpected unresolved symbols.

The architecture list is parsed natively and cross-checked with `lipo`. Undefined symbols are
read with `nm` once per architecture so a fat dylib cannot hide a failure in an unselected host
slice. Dependencies come from native Mach-O load-command parsing, not text output alone.

Forbidden markers include CydiaSubstrate, MobileSubstrate, libsubstrate, libhooker, ElleKit,
PreferenceLoader, `/var/jb`, common rootless preboot/bootstrap paths, and tweak-support paths.
An `@rpath` or `@loader_path` dependency is accepted only when its regular file is present inside
the export directory and no path component is a symbolic link or traversal component.

When `--target` is present, at least one dylib slice must match a device slice in architecture and
CPU subtype. A versioned arm64e match is exact. The verifier also compares minimum OS versions for
matching slices.

## Result meaning

`Ready for LiveContainer testing` means static preflight checks passed. It does not mean the patch
has already been exercised on a device. The next milestone records constructor execution,
immediate and delayed class patching, functional patch behavior, and loader limitations.
