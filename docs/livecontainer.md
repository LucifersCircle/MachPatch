# LiveContainer testing

The primary artifact is a plain, self-contained iPhoneOS dylib. Verification is a preflight audit;
it cannot prove that a particular LiveContainer version will load a dylib or that a runtime patch
will find its class. Those behaviors are exercised through the recorded device acceptance pass.

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
has already been exercised on a device. Class methods are installed on the metaclass. Actions that
preserve behavior store a typed original IMP; direct-return actions do not. Missing classes are
retried on the main queue at 1, 3, and 8 seconds before being marked failed.

## Import and test workflow

LiveContainer versions may use different labels for their app and dylib management controls. The
device workflow is otherwise the same:

1. Import the authorized decrypted IPA into LiveContainer.
2. Build the patch dylib against that exact IPA, app bundle, or executable.
3. Run `machpatch verify` with the same target and resolve every blocking result.
4. Transfer the verified plain `.dylib` to the device and add it to the imported app using
   LiveContainer's dylib-loading controls.
5. Enable only the dylib under test. Disable older probes or patches that target the same method.
6. Fully terminate the guest app after changing its dylib selection, then launch it again through
   LiveContainer.
7. Exercise the patched behavior. For log-only actions, use LiveContainer's logs when available or
   temporarily pair the action with a visible, target-specific test signal.

MachPatch does not copy artifacts into LiveContainer, modify an IPA, sign an app, or manage the
guest process. The exported dylib is intentionally the handoff boundary.

## Recorded device acceptance

The following behaviors were exercised with a decrypted arm64 iPhoneOS target whose minimum
deployment version was iOS 15.6. Each dylib passed `machpatch verify --target` before import:

- A constructor loaded without jailbreak libraries and installed an immediate Objective-C method
  replacement. A UIKit alert from that replacement appeared and the app remained stable.
- A schema-generated Boolean replacement changed `-[SettingsViewController debugOn]` from `NO` to
  `YES`; the app visibly selected its Debug option.
- An original-result action called the saved typed IMP, observed `NO`, logged the value, returned
  the same value, and emitted its one-time confirmation signal.
- A synthetic Objective-C class was absent during dylib initialization, registered later with an
  original `NO` method, and was changed to `YES` by the generated one-second retry.
- A synthetic late class deliberately supplied `q16@0:8` where the patch expected `B16@0:8`.
  Generated code took the unexpected-encoding logging branch, entered the permanent failed state,
  left the original method unchanged, and did not crash the process.

These checks cover the current runtime contract. They do not guarantee that an unrelated app,
OS version, architecture, or LiveContainer release behaves identically.

## Known limitations

- LiveContainer may not expose guest `NSLog` output in every configuration. Visible probes are a
  testing aid, not part of normal generated patches.
- Loading and signing are owned by LiveContainer. Passing static verification cannot prove that a
  particular LiveContainer build will accept or execute the dylib.
- Patch projects are bound to an executable hash, architecture/subtype, selector, and exact method
  type encoding. Re-analyze the target and rebuild after any app update.
- Retries are deliberately finite. A class that is still absent after the 8-second attempt is
  marked failed for the life of that process.
- Multiple dylibs can replace the same method in load-order-dependent ways. Isolate one test dylib
  at a time and fully restart the guest app between tests.
- The current patch model targets discovered Objective-C methods. It does not patch pure Swift,
  C, or C++ functions, and stripped or dynamically synthesized metadata may not be discoverable.
- Entitlements, anti-tamper logic, app-specific integrity checks, or OS policy can still prevent a
  verified dylib from loading or an otherwise valid app from running.
- Decrypted IPAs, extracted app bundles, executables, signing material, and device logs must remain
  outside the repository. Commit only source, documentation, synthetic fixtures, and hashes that
  are intentionally public.
