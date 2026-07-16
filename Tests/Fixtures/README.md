# Fixtures

This directory contains only purpose-built test inputs and programmatically generated binary
headers. Do not commit decrypted third-party applications.

The synthetic large-class catalog in `WorkspaceModelTests` exercises the same scale as the local
stress target without embedding proprietary metadata. For optional local timing acceptance, set
`MACHPATCH_STRESS_TARGET` as documented in `docs/release-checklist.md`; the configured target stays
outside the repository and the ordinary suite skips that test when the variable is absent.

A redistributable iOS runtime fixture is still required before a public release. It must cover
immediate and late-loaded Objective-C classes, an original-call path, scalar and object signatures,
a category target, and a separately selectable framework image.
