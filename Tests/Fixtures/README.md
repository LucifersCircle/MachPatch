# Fixtures

This directory contains only purpose-built test inputs and programmatically generated binary
headers. Do not commit decrypted third-party applications.

The synthetic large-class catalog in `WorkspaceModelTests` exercises the same scale as the local
stress target without embedding proprietary metadata. For optional local timing acceptance, set
`MACHPATCH_STRESS_TARGET` as documented in `docs/release-checklist.md`; the configured target stays
outside the repository and the ordinary suite skips that test when the variable is absent.

`RuntimeFixture` is the redistributable iOS app used by the end-to-end release gate. It covers
immediate and late-loaded Objective-C classes, original-call paths, scalar and object signatures,
categories, and a separately selectable embedded framework without including third-party code or
metadata. See its README for manual build and device instructions.
