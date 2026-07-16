# Generated runtime source

MachPatch intentionally has no editable or separately copied Objective-C runtime template. The
authoritative renderer is
[`Sources/MachPatchGenerator/ObjectiveCSourceGenerator.swift`](../../Sources/MachPatchGenerator/ObjectiveCSourceGenerator.swift).
It emits typed replacement functions, runtime installation, late-load retries, advanced effects,
and optional in-app controls from a validated patch project.

Keeping generation in Swift is part of the ABI-safety boundary: decoded signatures and compatible
actions are rendered together, and unsupported types cannot fall through to a text-template
substitution. Generator tests provide deterministic source assertions and compile generated probes
against the selected iPhoneOS SDK. See
[`docs/architecture.md`](../../docs/architecture.md) and
[`docs/patch-format.md`](../../docs/patch-format.md) for the runtime and source-generation contracts.
