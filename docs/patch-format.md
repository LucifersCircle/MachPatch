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
