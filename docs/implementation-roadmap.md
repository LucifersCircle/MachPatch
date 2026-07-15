# Implementation roadmap

This roadmap continues from the completed version 0.1 milestones. It is ordered to increase
useful patch coverage without weakening MachPatch's ABI-safety rule: a method is editable only
when the analyzer, validator, generator, and runtime installer agree on its exact signature.

The roadmap is intentionally split into reviewable commits. Every phase must leave the CLI,
SwiftUI application, generated source, and project JSON in agreement. Theos, Frida, pure Swift
symbol hooking, and C function hooking remain outside the current product scope.

## Working rules

- Measure the target before choosing which ABI feature to add next.
- Keep parsed metadata separate from policy and presentation.
- Represent unsupported cases explicitly; never coerce an unknown type into a supported one.
- Keep project and report models deterministic, `Codable`, and `Sendable`.
- Add focused unit tests for every new type or policy decision, then run the complete test suite.
- Use small local commits at phase boundaries. Device testing remains a separate acceptance gate
  whenever generated runtime behavior changes.
- Schema compatibility is not a release constraint yet. A schema revision may replace transitional
  structures when that reduces code and ambiguity, but fixtures and documentation must change in
  the same commit.

## Phase 1: target patchability report

### Outcome

Show what MachPatch can patch in the current target, what it cannot patch, and why. This report is
the evidence used to order later ABI work.

### Core implementation

- Add one shared signature evaluator in `MachPatchCore` that classifies a method declaration as
  patchable or unavailable.
- Use stable reason codes for missing encodings, decoding failures, invalid implicit `self`/`_cmd`
  arguments, selector/encoding arity mismatches, unsupported return types, unsupported explicit
  argument types, and an empty compatible-action set.
- Record the class, selector, instance/class kind, optional category origin, raw encoding, decoded
  signature when available, compatible actions, and the exact unavailable reason.
- Aggregate totals for class declarations and category declarations separately. Category methods
  that are ABI-compatible but not yet exposed in the editor must be visible as an opportunity, not
  silently counted as already usable.
- Keep ordering deterministic so text, JSON, and tests are reproducible.

### Frontends

- Add `machpatch patchability <target> [--json]`.
- Render a concise human report by default and the complete stable model with `--json`.
- Add a Patchability group to the target summary showing currently editable class declarations,
  additional compatible category declarations, unavailable declarations, and the leading reasons.
- Phrase counts as declarations rather than unique runtime selectors until category/class
  collisions are canonicalized in Phase 2.

### Tests and acceptance

- Cover every reason code with synthetic Objective-C metadata.
- Cover class and category aggregation, deterministic ordering, action lists, and JSON round trips.
- Confirm the CLI command succeeds against a known fixture binary and rejects invalid input like
  the existing inspection commands.
- Confirm the target summary remains usable with zero methods and with thousands of methods.

### Commit boundary

One Core/report commit may precede one CLI/GUI integration commit if review size warrants it. No
runtime patch behavior changes in this phase.

## Phase 2: category methods and property accessors

### Outcome

Turn metadata MachPatch already extracts into editor-visible patch targets.

### Category methods

- Merge category declarations into their owning class's method browser.
- Show an origin badge containing the category name.
- Canonicalize class/category declarations by runtime identity: class name, method kind, and
  selector. If encodings disagree, block editing and show the conflict rather than picking one.
- Preserve the declaring category in report/UI metadata, while keeping the runtime patch target as
  the owning class and selector.
- Search category names and category method selectors.

### Property accessors

- Decode getter and setter names from property attributes, including custom `G`/`S` attributes.
- Make properties selectable and link them to an existing accessor method declaration.
- Do not synthesize an accessor signature when the binary does not declare one.
- Explain read-only, missing-accessor, or unsupported-accessor cases inline.

### Tests and acceptance

- Test duplicate declarations, conflicting encodings, class methods in categories, custom property
  accessors, read-only properties, and missing methods.
- Build and device-test at least one category method patch before closing the phase.

## Phase 3: safe scalar ABI expansion

### Outcome

Add the highest-value signatures identified by Phase 1 while retaining exact typed trampolines.

### Floating-point family

- Add `float` and `double` values, conditions, return actions, argument replacement, logging, and
  original-result replacement.
- Treat `CGFloat` according to the analyzed target ABI rather than its source-level name. On the
  supported 64-bit iOS target it is encoded as `double`.
- Use locale-independent, round-trippable JSON and generated C literals. Reject NaN and infinities
  unless the UI and schema explicitly gain representations for them.

### Class and selector family

- Add a named-class return action for `Class` results.
- Add named-selector return and original-result replacement actions for `SEL` results.
- Validate runtime names before generation and provide explicit nil/NULL behavior where the ABI
  permits it.

### Tests and acceptance

- Add decoder/validator/generator snapshots for argument and return positions, conditions, before
  and after effects, and original calls.
- Compile probes for each signature on the selected iPhoneOS SDK.
- Device-test one floating-point return and one Class or SEL return before closing the phase.

## Phase 4: framework and image analysis

### Outcome

Analyze targets beyond the main application executable and make the selected runtime image
explicit throughout the workflow.

### Input and analysis

- Accept a `.framework` bundle by resolving its declared executable safely.
- Enumerate embedded dynamic frameworks and supported app-extension images without executing them.
- Hash and inspect every image independently. Preserve the host application identity separately
  from the selected image identity.
- Analyze only a user-selected image at a time to keep errors, architecture selection, and project
  targets unambiguous.

### Project and UI

- Add an image selector below Architectures and above class search.
- Display each image's path, architecture support, encryption status, and metadata availability.
- Include the selected image hash/name in project identity and validation so a patch cannot drift
  to another embedded framework with the same class name.
- Replace the current main-executable-only `isLikelyAppDefined` assumption with an explicit image
  origin plus a separately labeled heuristic.

### Tests and acceptance

- Cover standalone frameworks, apps with multiple frameworks, duplicate class names across images,
  missing framework executables, and architecture mismatch.
- Build and device-test a patch targeting an embedded framework class.

## Phase 5: conservative complex ABI tiers

### Pointer and block pass-through

- First allow opaque pointer and block arguments only when the action forwards the original value
  unchanged or logs a safe address/type description.
- Add explicit nil/NULL replacement only where ownership and calling convention remain unchanged.
- Do not dereference pointers or invoke blocks in generated presets.

### Selected structs

- Rank struct encodings from the Phase 1 report.
- Add exact support only for well-known layouts with SDK definitions and architecture-stable
  encodings, initially `CGPoint`, `CGSize`, `CGRect`, and `NSRange` if target data justifies them.
- Generate compile probes and exact typed function pointers for every supported layout.
- Keep arbitrary structs, unions, arrays, bitfields, variadics, and `long double` unavailable.

### Tests and acceptance

- Require compile probes plus device tests for every newly supported calling convention.
- A failure in any architecture probe blocks the type family rather than degrading to an unsafe
  cast.

## Phase 6: release closure

### Command-line and build provenance

- Add the planned CLI packaging command for source archives and Debian packages.
- Extend build records with deterministic target, project, generated-source, and output hashes,
  plus the final verification result.
- Add Build Dylib and Export Dylib to the hammer menu and appropriate native macOS menus, with
  state-aware enablement and shortcuts. Keep the existing in-app Build Workspace controls.

### Repeatable acceptance

- Add a redistributable fixture iOS app that exercises immediate, original-call, late-loaded,
  scalar, object, category, and framework patches.
- Automate source generation, compile, verification, and package checks around that fixture.
- Keep LiveContainer installation and launch as documented manual device gates.

### Product and repository finish

- Choose and add a project license before public release.
- Replace stale schema/template placeholder READMEs with generated or authoritative references.
- Add the remaining useful class filters: UIKit subclasses, third-party SDK heuristic, and image.
- Make patch logging destinations and levels understandable in the editor and generated output.
- Decide whether active-Xcode discovery is sufficient or a pre-build toolchain selector is needed.

## Deferred until evidence justifies them

- Inherited-method patching. A safe implementation must add a class-local override instead of
  replacing a superclass implementation shared by unrelated subclasses.
- Global protocol browsing. Protocol declarations are informative but are not runtime
  implementations and therefore are not direct patch targets.
- Arbitrary custom Objective-C source. Presets remain the safe default; a future custom-code mode
  needs a clear trust boundary, compilation diagnostics, schema representation, and warnings that
  MachPatch cannot prove runtime safety.
- Pure Swift symbols, C functions, C++ methods, Swift async calling conventions, variadics, and
  jailbreak-specific hooking frameworks.

## Completion definition

The roadmap is complete when the report shows that remaining unsupported declarations fall into
documented deferred ABI families, all editor-visible types share validation and generation rules,
the fixture workflow passes, release artifacts contain reproducible provenance, and the GUI and
CLI expose the same supported capabilities.
