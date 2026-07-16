# Patch-project schema resources

MachPatch's authoritative project schema is the versioned `Codable` model in
[`Sources/MachPatchCore/PatchProjectModels.swift`](../../Sources/MachPatchCore/PatchProjectModels.swift),
[`Sources/MachPatchCore/AdvancedPatchModels.swift`](../../Sources/MachPatchCore/AdvancedPatchModels.swift),
and
[`Sources/MachPatchCore/PatchRuntimeControlModels.swift`](../../Sources/MachPatchCore/PatchRuntimeControlModels.swift).
The codec and validator—not a separately maintained JSON Schema file—define what MachPatch accepts:

- [`PatchProjectCodec.swift`](../../Sources/MachPatchCore/PatchProjectCodec.swift) provides the
  deterministic JSON representation;
- [`PatchProjectValidation.swift`](../../Sources/MachPatchCore/PatchProjectValidation.swift)
  enforces structural and cross-field rules; and
- [`docs/patch-format.md`](../../docs/patch-format.md) is the user-facing format reference.

[`Examples/ExamplePatch.json`](../../Examples/ExamplePatch.json) is the checked-in version 1
example. Core round-trip and validation tests must change with any schema revision. Keeping those
artifacts tied to the executable model avoids publishing a permissive JSON Schema that accepts
projects the ABI validator would reject.
