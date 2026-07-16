// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MachPatch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "machpatch", targets: ["MachPatchCLI"]),
        .executable(name: "MachPatchApp", targets: ["MachPatchApp"]),
        .library(name: "MachPatchCore", targets: ["MachPatchCore"]),
        .library(name: "MachPatchAnalyzer", targets: ["MachPatchAnalyzer"]),
        .library(name: "MachPatchGenerator", targets: ["MachPatchGenerator"]),
        .library(name: "MachPatchBuilder", targets: ["MachPatchBuilder"]),
        .library(name: "MachPatchVerifier", targets: ["MachPatchVerifier"]),
        .library(name: "MachPatchPackager", targets: ["MachPatchPackager"]),
    ],
    targets: [
        .executableTarget(
            name: "MachPatchApp",
            dependencies: [
                "MachPatchAnalyzer", "MachPatchBuilder", "MachPatchCore", "MachPatchGenerator",
                "MachPatchPackager", "MachPatchVerifier",
            ]
        ),
        .executableTarget(
            name: "MachPatchCLI",
            dependencies: [
                "MachPatchAnalyzer", "MachPatchBuilder", "MachPatchCore", "MachPatchGenerator",
                "MachPatchPackager", "MachPatchVerifier",
            ]
        ),
        .target(name: "MachPatchCore"),
        .target(
            name: "MachPatchAnalyzer",
            dependencies: ["MachPatchCore"],
            resources: [.copy("Resources/lief_objc_analyzer.py")]
        ),
        .target(
            name: "MachPatchGenerator",
            dependencies: ["MachPatchCore"]
        ),
        .target(
            name: "MachPatchBuilder",
            dependencies: ["MachPatchAnalyzer", "MachPatchCore", "MachPatchGenerator"]
        ),
        .target(
            name: "MachPatchVerifier",
            dependencies: ["MachPatchCore", "MachPatchAnalyzer"]
        ),
        .target(
            name: "MachPatchPackager",
            dependencies: ["MachPatchCore", "MachPatchBuilder", "MachPatchVerifier"]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["MachPatchCore"]
        ),
        .testTarget(
            name: "AnalyzerTests",
            dependencies: ["MachPatchAnalyzer"]
        ),
        .testTarget(
            name: "GeneratorTests",
            dependencies: ["MachPatchGenerator"],
            resources: [.copy("Snapshots")]
        ),
        .testTarget(
            name: "BuilderTests",
            dependencies: ["MachPatchBuilder"]
        ),
        .testTarget(
            name: "VerifierTests",
            dependencies: ["MachPatchAnalyzer", "MachPatchCore", "MachPatchVerifier"]
        ),
        .testTarget(
            name: "PackagerTests",
            dependencies: ["MachPatchBuilder", "MachPatchCore", "MachPatchPackager"]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "MachPatchApp", "MachPatchBuilder", "MachPatchCore", "MachPatchGenerator",
                "MachPatchPackager", "MachPatchVerifier",
            ]
        ),
        .testTarget(
            name: "RuntimeFixtureTests",
            dependencies: [
                "MachPatchAnalyzer", "MachPatchBuilder", "MachPatchCore", "MachPatchGenerator",
                "MachPatchPackager", "MachPatchVerifier",
            ]
        ),
    ]
)
