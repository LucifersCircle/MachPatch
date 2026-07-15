# Patch format

MachPatch projects use versioned declarative JSON. Generated Objective-C source and compiled
dylibs are build products; neither is the canonical project representation.

The current format version is `1`. See [Examples/ExamplePatch.json](../Examples/ExamplePatch.json)
for a complete file.

## Project fields

The top-level object contains:

- `formatVersion`: must be `1`;
- `projectName`: user-visible project name;
- `target`: immutable host, selected-image, and selected Mach-O slice identity;
- `build`: requested architecture mode, deployment target, output name, and ARC setting;
- `patches`: ordered method-patch definitions.

Target identity records the host bundle identifier, executable name, and SHA-256 separately from
the selected image's kind, relative path, bundle identifier, executable name, and SHA-256. It also
records the minimum iOS version, architecture, and raw CPU subtype. A changed host or same-path
image hash is a retargeting warning. Selecting a different image path or name is an error even if
that image exposes an identical Objective-C class and selector. Version 1 projects written before
the `selectedImage` field existed decode it as the primary executable for compatibility.

Each patch records a UUID string, enabled state, exact class and selector, instance/class method
kind, raw expected type encoding, and typed action. Duplicate IDs or duplicate method targets are
rejected.

## Version 1 actions

Actions use a `kind` discriminator. Value-producing actions include a JSON `value`:

```json
{ "kind": "returnBoolean", "value": true }
{ "kind": "returnSignedInteger", "value": -42 }
{ "kind": "returnUnsignedInteger", "value": 42 }
{ "kind": "returnFloatingPoint", "value": 1.25 }
{ "kind": "returnClassNamed", "value": "NSString" }
{ "kind": "returnSelector", "value": "description" }
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

Replacement kinds are `boolean`, `signedInteger`, `unsignedInteger`, `floatingPoint`, `nil`,
`classNamed`, `selector`, and `string`. `nil` represents Objective-C `nil`, Class `Nil`, or SEL
`NULL` according to the decoded return type. Named classes are resolved with `objc_getClass` and
therefore return `Nil` when the class is unavailable. Named selectors are registered with
`sel_registerName`.

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

Argument values and comparisons are validated against the decoded ABI type. Floating-point
values use JSON numbers and must be finite; NaN, infinities, and values outside the encoded
`float` range are rejected. Ordered comparisons support integer, `float`, and `double` sources.
After-effects and
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

Compatible signatures allow Boolean (`B`), signed and unsigned integer scalars, `float` (`f`),
`double` (`d`), Objective-C objects, class objects, selectors, and `void` returns. On supported
64-bit iOS targets, an Objective-C `CGFloat` is represented by its analyzed `double` encoding; no
source-level typedef guess is made. Legacy `c` is an integer by default, never an implicit
Boolean.

Opaque pointer and block arguments are supported conservatively. They are accepted only by primary
actions that call the original implementation, logged as addresses without dereferencing pointers
or describing/invoking blocks, and may be replaced or compared only with explicit `NULL`/`nil`.
Pointer and block return values remain unavailable.

Four exact 64-bit iOS structure layouts are supported in argument and return positions: `CGPoint`,
`CGSize`, `CGRect`, and `NSRange`. The structure name and complete decoded field layout must match;
look-alike and anonymous structures remain unavailable. These values use typed pass-through and
field logging only—MachPatch does not synthesize structure constants, replacements, or ordered
conditions. Long double, C strings, arrays, arbitrary structures, unions, bit fields, and unknown
types remain rejected.

Selector colon count must match the number of explicit encoded arguments. Integer constants must
fit the encoded width. Floating-point constants are rendered as locale-independent,
round-trippable C literals after validation. Object strings are valid only for object returns,
while `nil`/`NULL` is valid for object, class-object, selector, opaque-pointer argument, or block
argument values.

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

Floating-point trampolines use exact `float` or `double` function-pointer types in argument and
return positions. Logging promotes `float` to `double` for the variadic call and uses enough
significant digits to preserve the encoded scalar value. Class and selector results remain typed
as `Class` and `SEL`; they are never represented as integer or opaque pointer literals.
Block arguments use an opaque Objective-C object parameter and pointer arguments use `void *`;
generated presets never invoke or dereference them. Known structures use the SDK's exact named C
types, and generation imports CoreGraphics only when a `CGPoint`, `CGSize`, or `CGRect` is present.

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
