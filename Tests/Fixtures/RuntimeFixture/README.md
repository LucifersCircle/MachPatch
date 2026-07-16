# MachPatch runtime fixture

This purpose-built iOS app is redistributable and contains no third-party application code or
metadata. It provides stable Objective-C targets for release acceptance:

- immediate boolean, signed-integer, object, void-with-arguments, `CGRect`, `NSRange`, and block
  methods in `MPFixtureController`;
- a category method on the declared controller;
- `MPFixtureLateTarget` in an embedded framework that the app loads only after the user presses
  **Load Framework Target**; and
- a framework category on `NSObject`, which appears as a category-only runtime target.

Build the unsigned-development fixture with the active Xcode iPhoneOS SDK:

```bash
Tests/Fixtures/RuntimeFixture/build.sh /tmp/MachPatchFixture
```

The script produces an ad-hoc-signed `MachPatchRuntimeFixture.app`. The app's two buttons invoke
the immediate and late-loaded target methods and show their results on screen, making device patch
behavior observable without relying on console access.

Run the automated end-to-end gate with:

```bash
swift test --filter RuntimeFixtureTests
```

That test builds the app and framework, resolves and analyzes both images, generates and compiles
immediate and late-loaded patch projects, verifies their dylibs, and packages the main project as
both a source archive and Debian package. It uses the analyzed method encodings rather than a
parallel hand-written model, so analyzer regressions also fail the workflow.

For device acceptance, load the generated app into the authorized test environment, use MachPatch
to create patches for the methods above, inject the verified dylib, and compare the values shown by
the two fixture buttons. The framework button deliberately loads `MPFixtureKit` only after it is
pressed, which exercises generated late-class retry behavior.
