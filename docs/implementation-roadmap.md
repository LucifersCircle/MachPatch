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

## Phase 6: release engineering

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

### Tests and acceptance

- Prove that equivalent GUI and CLI packaging requests produce equivalent artifacts and
  verification results.
- Verify that build provenance changes when and only when its corresponding input changes.
- Exercise menu enablement with no target, an invalid project, a stale build, a verified build,
  and each supported export format.
- Run the complete fixture workflow without relying on a decrypted third-party application.

## Phase 7: opt-in runtime controls

The generated runtime surface is larger and more invasive than an ordinary method patch, so
design and threat modeling precede implementation. Phase 8 release polish and its public-release
gate follow only after these controls pass their separate device safety checks.

### Project and state model

- Keep an always-visible Build Workspace checklist where users explicitly choose which patches
  appear in the generated control menu without navigating back to each method editor.
- Use the floating button as the discoverable entry point and let projects hide it at startup.
  Always install a three-finger recovery gesture when controls are generated so the user can reveal
  a startup-hidden button or recover it after its session hide action.
- Give every exposed patch one unambiguous Patch/Original switch. Patch runs the complete saved
  patch configuration; Original bypasses every patch action and advanced effect for that invocation.
  Do not expose individual return values or argument replacements as runtime editors.
- Give every exposed control a stable identifier, user-facing title, and default Patch/Original
  selection. Always restore its last runtime selection on target launch. Let users order controls
  in the menu and namespace persisted state by target identity and patch project.
- Keep disabled project patches out of builds. A runtime-disabled exposed patch remains installed
  but forwards the original invocation unchanged.

### Generated runtime and overlay

- Use an in-process state registry shared by the overlay and generated hooks. Do not require Darwin
  notifications unless a future controller operates from another process.
- Install controls only when at least one patch is exposed. The floating entry point is a 52-point
  circular material button with a system hammer symbol, a half-clipped edge-resting position,
  low-opacity idle treatment, edge snapping, dragging, VoiceOver labels, and a session-only hide
  action that always recovers on relaunch. VoiceOver fallback keeps the button fully visible.
- Present a compact scrolling material panel with ordered control rows, optional technical method
  subtitles, colored Patch/Disabled status, and reset-to-defaults. Each row is authoritative; do not add a global
  bypass that can obscure an individual patch's Patch/Original selection.
  Touches outside the button and open panel pass through to the target application.
- Implement a fixed three-second, three-finger long press with a non-cancelling recognizer
  and haptic confirmation when it succeeds. It only recovers a session-hidden button. Never install this recognizer
  while VoiceOver is active. Observe VoiceOver status changes; if it turns on, immediately remove
  every MachPatch gesture recognizer and expose the accessible floating button for the rest of the
  session. This fallback must not consume VoiceOver gestures.
- Attach one overlay to each active window scene while sharing one process-wide control registry.
  Reconcile foregrounding, disconnection, rotation, and safe-area changes without duplicating state.
- Avoid private APIs, avoid intercepting unrelated application events, and keep all UI work on the
  main thread.
- Make every controlled hook read state cheaply and atomically without changing the typed original
  calling convention. Read the enabled state once at invocation start so a concurrent UI edit
  cannot split one invocation across two configurations.
- When a selected class inherits the target method, add a class-local override instead of mutating
  the superclass method. Preserve the baseline IMP across multiple generated superclass/subclass
  patches so each control remains independent.

### Safety and acceptance

- Warn that the generated overlay becomes part of the target app's UI and may affect screenshots,
  automation, and application review behavior.
- Test launch timing, late-loaded classes, scene changes, rotations, repeated foregrounding,
  multiple windows, VoiceOver fallback, gesture conflicts, persistence, and projects with no
  exposed controls.
- Device-test toggles for immediate and late-loaded patches, verify that runtime-disabled patches
  call the original unchanged, and confirm the target launches when overlay setup cannot complete.
- Make it explicit that switching to Original affects future invocations only; it cannot reverse
  target state already cached or persisted by earlier patched invocations.

## Phase 8: stability and product polish

### Unified unsaved-changes protection

- Use one dirty-state guard before New Patch, Load Patch, Import Patch, Open Target, and switching
  the selected target image or framework.
- Offer Save and Continue, Discard Changes, and Cancel. Never overwrite a dirty project or trap
  the user behind a save-only warning.
- Treat an internal library save or exported patch-project JSON as a saved project baseline.
  Dylib, source, and Debian artifact exports do not save the editable patch project.
- Preserve the requested navigation action while the save panel or confirmation is active, then
  perform it exactly once after a successful save or explicit discard.

### Large-target performance

- Profile target analysis, class and method filtering, SwiftUI invalidation, patch editing, source
  generation, and per-image selection before choosing optimizations.
- Cache immutable analysis and search indexes by target image identity. Do not repeat Mach-O or
  Objective-C metadata work merely because the selection or editor state changed.
- Debounce text search and avoid regenerating source or filtering every declaration for unrelated
  view updates.
- Use the current 3,461-class, roughly 46,000-method ScrabbleGo target as the local stress case,
  while keeping redistributable synthetic performance fixtures in the test suite.

### Editing and navigation polish

- Make Remove Patch use the application accent and require a confirmation whose destructive
  action uses native destructive styling.
- Pin Build Workspace outside the scrolling class list so it remains reachable at every scroll
  position and window size.
- Add the native macOS share sheet after patch-project, dylib, source, and Debian exports without
  changing the existing explicit save/export destinations.
- Add the remaining useful class filters: UIKit subclasses, third-party SDK heuristic, and image.
- Make patch logging destinations and levels understandable in the editor and generated output.
- Decide whether active-Xcode discovery is sufficient or a pre-build toolchain selector is needed.

### Product and repository finish

- Choose and add a project license before public release.
- Replace stale schema/template placeholder READMEs with generated or authoritative references.
- Verify keyboard navigation, accessibility labels, narrow-window layouts, and native menu parity.
- Exercise malformed projects, missing targets, missing Xcode installations, failed builds, stale
  artifacts, and clean-machine first launch with actionable recovery messages.

### Tests and acceptance

- Add model tests for every dirty-state transition and UI tests for Save, Discard, and Cancel from
  every guarded operation.
- Confirm patch deletion cannot occur without confirmation and leaves selection and build state
  consistent after deletion.
- Measure and record the stress target's initial load, class search, method search, patch mutation,
  and image-switch timings before and after optimization.
- Verify every export can invoke the native share picker with the exact completed artifact.

## Deferred until evidence justifies them

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
the fixture workflow passes, release artifacts contain reproducible provenance, destructive
navigation cannot lose work, the stress target remains responsive, GUI and CLI capabilities agree,
and opt-in runtime controls pass their separate device safety gates.
