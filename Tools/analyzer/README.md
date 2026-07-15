# Analyzer helpers

The current proof-of-concept LIEF Extended bridge is bundled as a SwiftPM resource at
`Sources/MachPatchAnalyzer/Resources/lief_objc_analyzer.py`. `ObjectiveCAnalyzer` launches it
through a normalized provider boundary and falls back to Apple's `xcrun otool` when its probe says
the Extended Objective-C API is unavailable.

This directory is reserved for a future distributable helper executable, such as a LIEF C++
bridge. Replacing the Python helper must not change the public `ObjectiveCMetadata` models or CLI
JSON schema.
