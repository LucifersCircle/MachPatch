# Patch format

MachPatch projects use versioned declarative JSON. Generated Objective-C source and compiled
dylibs are build products; neither is the canonical project representation.

The current format version is `1`. See [Examples/ExamplePatch.json](../Examples/ExamplePatch.json)
for a complete file.

## Project fields

The top-level object contains:

- `formatVersion`: must be `1`;
- `projectName`: user-visible project name;
- `target`: immutable identity of the executable and selected Mach-O slice used to create it;
- `build`: requested architecture mode, deployment target, output name, and ARC setting;
- `patches`: ordered method-patch definitions.

Target identity records the bundle identifier when available, executable name and SHA-256,
minimum iOS version, architecture, and raw CPU subtype. A changed hash, name, bundle identifier,
or minimum OS is reported as a retargeting warning. A missing architecture/subtype is an error.

Each patch records a UUID string, enabled state, exact class and selector, instance/class method
kind, raw expected type encoding, and typed action. Duplicate IDs or duplicate method targets are
rejected.

## Version 1 actions

Actions use a `kind` discriminator. Value-producing actions include a JSON `value`:

```json
{ "kind": "returnBoolean", "value": true }
{ "kind": "returnSignedInteger", "value": -42 }
{ "kind": "returnUnsignedInteger", "value": 42 }
{ "kind": "returnString", "value": "Fixture" }
{
  "kind": "returnObject",
  "object": { "kind": "arrayOfStrings", "value": ["one", "two"] }
}
```

Actions without a direct value are:

```json
{ "kind": "returnNil" }
{ "kind": "logInvocation" }
{ "kind": "logArguments" }
{ "kind": "logOriginalReturnValue" }
{ "kind": "callOriginal" }
```

Calling the original implementation and replacing its result uses a typed replacement:

```json
{
  "kind": "callOriginalAndReplace",
  "replacement": { "kind": "boolean", "value": false }
}
```

Replacement kinds are `boolean`, `signedInteger`, `unsignedInteger`, `nil`, and `string`.

Foundation object construction supports Boolean, signed, and unsigned `NSNumber` values,
string-only arrays and dictionaries, and `NSURL` values. It is available only for Objective-C
object returns.

## Advanced behavior

An optional `advanced` object composes behavior around the primary action. It can contain:

- typed `argumentReplacements`, applied before calling the original implementation;
- ordered `beforeEffects` and `afterEffects` containing alert presets or custom Objective-C;
- one `conditionalReturn` based on an explicit argument or the invocation count; and
- a thread-safe `invocationCounter`, with optional per-invocation logging.

For example:

```json
{
  "argumentReplacements": [
    { "argumentIndex": 0, "value": { "kind": "boolean", "value": true } }
  ],
  "beforeEffects": [
    {
      "kind": "showAlert",
      "alert": {
        "title": "MachPatch",
        "message": "Method invoked",
        "buttonTitle": "OK"
      }
    }
  ],
  "afterEffects": [],
  "conditionalReturn": {
    "condition": {
      "source": { "kind": "invocationCount" },
      "comparison": "greaterThan",
      "value": { "kind": "unsignedInteger", "value": 3 }
    },
    "replacement": { "kind": "boolean", "value": false }
  },
  "invocationCounter": { "logEachInvocation": false }
}
```

Argument values and comparisons are validated against the decoded ABI type. After-effects and
argument replacement require a primary action that calls the original implementation. Invocation
count conditions require the counter. Alert text is size-limited and presented asynchronously on
the main queue. If any alert is already visible, a generated alert request is discarded rather
than queued, preventing frequently invoked methods from building an alert backlog.

Custom Objective-C is expert mode. Snippets are emitted inside the generated replacement function,
where `self`, `_cmd`, and `argument0` through `argumentN` are in scope. Non-void after-effects also
receive `originalResult`. Snippets cannot contain preprocessor directives and are capped at 16 KiB;
the normal Xcode build diagnostics report syntax or type errors. MachPatch can validate the method
ABI and compile the snippet, but it cannot guarantee that arbitrary custom code is runtime-safe.

## Type safety

The decoder preserves raw encodings and tokenizes scalar types, objects and class annotations,
selectors, qualifiers, pointers, arrays, structs, unions, bit fields, blocks, and unknown types.
Method frame sizes and argument offsets are accepted but are not treated as types.

MVP-compatible signatures allow Boolean (`B`), signed and unsigned integer scalars, Objective-C
objects, class objects, selectors as arguments, and `void` returns. Legacy `c` is an integer by
default, never an implicit Boolean. Floating point, C strings, pointers, arrays, structures,
unions, bit fields, blocks, and unknown types are decoded but rejected for patch generation until
their complete ABI behavior is implemented.

Selector colon count must match the number of explicit encoded arguments. Integer constants must
fit the encoded width. Object strings are valid only for object returns, while `nil` is valid for
object or class-object returns.

## Validation

Schema and action compatibility validation does not need the original target:

```bash
machpatch validate-project patch.json
```

Because a project intentionally stores identity rather than a machine-specific source path, class
and method compatibility require an explicit current target:

```bash
machpatch validate-project patch.json --target /path/to/Target.ipa
```

Target-backed validation selects the exact recorded architecture and CPU subtype, then verifies
the class, selector, method kind, and raw type encoding. Reports are stable JSON. Validation exits
nonzero when `isValid` is false; retargeting warnings alone do not make the project invalid.

## Source generation

```bash
machpatch generate patch.json --output Generated
```

Disabled patches remain in the canonical project but are omitted from generated source. Enabled
patches retain their original project indices in generated C identifiers, so output is
deterministic and identifiers cannot collide after sanitization.

Direct return actions replace behavior without storing the previous IMP. Logging actions,
`callOriginal`, and `callOriginalAndReplace` store and invoke an ABI-matched original function
pointer. `logInvocation` and `logArguments` call the original unchanged;
`logOriginalReturnValue` calls, logs, and returns it. `callOriginalAndReplace` calls the original
before returning its typed replacement.

Advanced effects are emitted in deterministic project order. Counters use atomic increments.
Conditional returns run after before-effects and before argument replacement. Alerts add UIKit to
the generated source; ordinary patches remain Foundation/runtime-only.

Generated installation checks the complete raw encoding with `strcmp` before modifying a method.
An encoding mismatch is permanent. Missing classes or methods remain pending for bounded retries.

## Architecture and build output

```bash
machpatch build patch.json --output Build --arch automatic
```

The version 1 `build.minimumIOSVersion`, `build.outputName`, and `build.enableARC` values directly
control Clang's device deployment target, output filename, and ARC flag. The builder appends
`.dylib` to `outputName` and sets the install name to `@rpath/<outputName>.dylib`.

Architecture modes are `automatic`, `arm64`, `arm64e`, and `universal`. The CLI `--arch` option
overrides the stored mode for one build without rewriting the project. Automatic mode follows the
recorded selected slice. Explicit arm64/arm64e modes must match it; modern arm64e additionally
requires an exact versioned CPU-subtype match with the toolchain probe. Legacy arm64e is rejected.

Universal mode builds and validates separate `<outputName>-arm64.dylib` and
`<outputName>-arm64e.dylib` files before creating `<outputName>.dylib`. Successful output includes
the generated source and build-record format 2, which captures the resolution reason, capability
probes, exact compiler and lipo invocations, diagnostics, and parsed slice metadata.
