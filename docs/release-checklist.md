# Release checklist

This checklist separates automated guarantees from manual macOS and device acceptance. A release
candidate is not ready merely because the unit tests pass.

## Automated gates

Run from the repository root:

```bash
swift test
swift test --filter RuntimeFixtureTests
swift build --product MachPatchApp
swift build --product machpatch
Scripts/create-release-dmg.sh /tmp/MachPatchRelease 0.1.0
git diff --check
```

The suite covers deterministic project encoding, malformed-project diagnostics, target and image
validation, dirty-state transitions, destructive patch confirmation, source generation, toolchain
discovery failures, dylib verification, build provenance, source and Debian packaging, shareable
artifact state, narrow-window layout calculations, and runtime-control generation.

The release DMG must contain an arm64 `MachPatch.app` and an Applications shortcut. Verify its
checksum and mountability before publishing. A manual **Release** workflow run exercises this path
without creating a GitHub Release; a matching `v*` tag publishes the DMG and checksum as release
assets.

## Redistributable runtime fixture

`Tests/Fixtures/RuntimeFixture` is a purpose-built iOS app with an embedded, explicitly late-loaded
framework. It contains no decrypted or third-party application code. The `RuntimeFixtureTests`
gate builds that target using the active iPhoneOS SDK, analyzes its immediate and framework images,
generates and compiles scalar, object, structure, block, category, original-call, and late-loaded
patches, verifies the dylibs, and packages source and Debian artifacts.

For the manual device pass, build the fixture and follow its README:

```bash
Tests/Fixtures/RuntimeFixture/build.sh /tmp/MachPatchFixture
```

## Large-target performance

The opt-in acceptance test never records or copies the configured target. Point it at an
authorized decrypted IPA, app bundle, framework, or Mach-O executable that remains outside the
repository:

```bash
MACHPATCH_STRESS_TARGET=/absolute/path/to/target \
  swift test --filter WorkspaceModelTests/testConfiguredStressTargetPerformance
```

The ordinary test suite skips this test when `MACHPATCH_STRESS_TARGET` is absent. Record timings
from the `MACHPATCH_STRESS_RESULT` line when preparing a release candidate.

### Current development measurement

Measured on 2026-07-15 using an arm64 Mac, macOS 27.0 (26A5353q), Xcode 26.6 (17F113), and a local
authorized stress target. The target itself is not redistributable and is not part of the
repository.

| Operation | Fixture size or result | Time |
| --- | ---: | ---: |
| Initial target load and Objective-C analysis | 3,527 classes / 46,960 methods | 5,753.81 ms |
| Class search | matching a class in the middle of the catalog | 60.92 ms |
| Method search | largest discovered class | 0.61 ms |
| Add and remove one compatible patch | generated preview invalidation included | 0.48 ms |
| Switch to and analyze another image | AppLovinSDK framework | 861.95 ms |

These are development measurements, not cross-machine performance promises. Repeat them on the
release candidate and investigate meaningful regressions before tagging it.

## macOS UI acceptance

- Start on a clean user account or clean application-support directory and verify the empty state,
  Open Target flow, and saved-patch library recover without hidden setup.
- Use keyboard navigation through the sidebar, class and method search, patch editor, Build
  Workspace, and confirmation dialogs.
- Verify VoiceOver announces Open Target, Build Workspace, project actions, patch controls, and
  destructive confirmations without relying only on color or icons.
- Exercise the minimum supported window size and a large window. No section may move off-screen or
  collapse into an unusable nested scroll area.
- Confirm File exposes Open Target and patch-project actions. Confirm Build exposes build/rebuild,
  dylib/source/Debian export, and matching share actions with state-aware enablement.
- Build once, then verify each share action opens the native picker for the exact completed
  artifact without marking the project or build stale.
- Exercise Save and Continue, Discard Changes, and Cancel before New Patch, Load/Import Patch, Open
  Target, architecture changes, and image/framework changes.
- Exercise missing target files, malformed project JSON, missing/full Xcode selection, a compiler
  failure, a stale artifact after editing, and an export failure. Each result must explain a useful
  recovery action.

## Device and LiveContainer acceptance

- Install a verified ordinary-arm64 dylib and confirm the target launches without a startup crash.
- Exercise immediate and late-loaded patches, original-call actions, supported scalar and object
  values, categories, and a framework image.
- Exercise every newly supported calling convention with its compile probe and a device invocation.
- Enable the opt-in runtime overlay, switch each exposed patch between Patch and Original, relaunch,
  and confirm the saved state applies to future invocations. Confirm VoiceOver prevents gesture
  activation and overlay setup failure leaves the target usable.
- Remember that switching to Original cannot undo state that the target already cached or persisted
  during an earlier patched invocation.

See [livecontainer.md](livecontainer.md) for the detailed verifier and device workflow.

## Public-release blockers

- Choose and add the project license.
- Rerun and record the macOS UI, performance, and device gates against the exact release commit.
