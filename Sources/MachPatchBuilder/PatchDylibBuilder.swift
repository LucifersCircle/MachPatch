import Foundation
import MachPatchAnalyzer
import MachPatchCore
import MachPatchGenerator

public struct PatchDylibBuilder: Sendable {
    private let commandRunner: any BuildCommandRunning
    private let architectureProber: any ToolchainArchitectureProbing

    public init(commandRunner: any BuildCommandRunning = ProcessBuildCommandRunner()) {
        self.commandRunner = commandRunner
        architectureProber = ClangArchitectureCapabilityProber(commandRunner: commandRunner)
    }

    public init(
        commandRunner: any BuildCommandRunning,
        architectureProber: any ToolchainArchitectureProbing
    ) {
        self.commandRunner = commandRunner
        self.architectureProber = architectureProber
    }

    public func build(
        _ project: PatchProject,
        outputDirectory: URL,
        architectureMode: PatchArchitectureMode? = nil,
        progress: @Sendable (PatchBuildProgress) -> Void = { _ in }
    ) throws -> PatchBuildRecord {
        let resolution = try ArchitectureResolver.resolve(
            mode: architectureMode ?? project.build.architectureMode,
            selectedSlice: project.target.selectedSlice
        )
        let universalStepCount = resolution.outputArchitecture == .universal ? 2 : 0
        let totalUnitCount = 3 + (resolution.slices.count * 2) + universalStepCount
        var completedUnitCount = 0

        func report(
            _ phase: PatchBuildPhase,
            architecture: BuildSliceArchitecture? = nil,
            message: String
        ) {
            progress(
                PatchBuildProgress(
                    phase: phase,
                    architecture: architecture,
                    completedUnitCount: completedUnitCount,
                    totalUnitCount: totalUnitCount,
                    message: message
                )
            )
        }

        report(.generatingSource, message: "Generating deterministic Objective-C source…")
        let projectData = try PatchProjectCodec.encode(project)
        let sourceBundle = try ObjectiveCSourceGenerator().generate(project)
        let outputDirectory = outputDirectory.standardizedFileURL
        let sourceURL =
            try GeneratedSourceWriter.write(
                sourceBundle,
                to: outputDirectory
            ).first ?? outputDirectory.appending(path: MachPatchGenerator.generatedSourceFileName)
        completedUnitCount += 1

        let baseName = project.build.outputName
        let outputFileName = "\(baseName).dylib"
        let outputURL = outputDirectory.appending(path: outputFileName)
        let arm64URL = outputDirectory.appending(path: "\(baseName)-arm64.dylib")
        let arm64eURL = outputDirectory.appending(path: "\(baseName)-arm64e.dylib")
        let recordURL = outputDirectory.appending(path: MachPatchBuilder.buildRecordFileName)
        let productURLs = [outputURL, arm64URL, arm64eURL]
        for url in productURLs + [recordURL] {
            try removePreviousRegularFile(at: url)
        }

        report(.discoveringToolchain, message: "Discovering the selected Xcode toolchain…")
        let toolchain = try AppleToolchainDiscoverer(commandRunner: commandRunner).discover()
        completedUnitCount += 1
        let installName = "@rpath/\(outputFileName)"

        do {
            let probes = try resolution.slices.map { architecture in
                report(
                    .probingArchitecture,
                    architecture: architecture,
                    message: "Checking \(architecture.rawValue) compiler capability…"
                )
                let probe = try architectureProber.probe(
                    architecture,
                    toolchain: toolchain,
                    minimumIOSVersion: project.build.minimumIOSVersion
                )
                try validateProbe(
                    probe,
                    resolution: resolution,
                    minimumIOSVersion: project.build.minimumIOSVersion
                )
                completedUnitCount += 1
                return probe
            }

            var sliceRecords: [PatchBuildSliceRecord] = []
            for architecture in resolution.slices {
                report(
                    .compiling,
                    architecture: architecture,
                    message: "Compiling the \(architecture.rawValue) dylib slice…"
                )
                let sliceURL: URL =
                    resolution.outputArchitecture == .universal
                    ? (architecture == .arm64 ? arm64URL : arm64eURL)
                    : outputURL
                let probe = try requiredProbe(for: architecture, in: probes)
                sliceRecords.append(
                    try compileSlice(
                        architecture,
                        project: project,
                        resolution: resolution,
                        probe: probe,
                        toolchain: toolchain,
                        sourceURL: sourceURL,
                        outputURL: sliceURL,
                        installName: installName
                    )
                )
                completedUnitCount += 1
            }

            let symbolChecks: [BuildCommandExecution]
            let merge: BuildCommandExecution?
            if resolution.outputArchitecture == .universal {
                report(
                    .inspectingSymbols,
                    message: "Comparing exported symbols across slices…"
                )
                symbolChecks = try compareExportedSymbols(
                    records: sliceRecords,
                    toolchain: toolchain
                )
                completedUnitCount += 1
                report(.merging, message: "Merging validated slices into a universal dylib…")
                merge = try mergeUniversal(
                    records: sliceRecords,
                    toolchain: toolchain,
                    outputURL: outputURL,
                    minimumIOSVersion: project.build.minimumIOSVersion,
                    installName: installName
                )
                completedUnitCount += 1
            } else {
                symbolChecks = []
                merge = nil
            }

            report(.recordingOutput, message: "Recording reproducible build metadata…")
            let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            let record = PatchBuildRecord(
                projectName: project.projectName,
                architecture: resolution.outputArchitecture,
                minimumIOSVersion: project.build.minimumIOSVersion,
                installName: installName,
                sourcePath: sourceURL.path,
                outputPath: outputURL.path,
                recordPath: recordURL.path,
                toolchain: toolchain,
                architectureResolution: resolution,
                capabilityProbes: probes,
                slices: sliceRecords,
                symbolChecks: symbolChecks,
                merge: merge,
                provenance: PatchBuildProvenance(
                    targetExecutableSHA256: project.target.executableSHA256,
                    selectedImageSHA256: project.target.selectedImage.executableSHA256,
                    projectSHA256: PatchBuildContentHasher.sha256(projectData),
                    generatedSourceSHA256: PatchBuildContentHasher.sha256(sourceData),
                    outputSHA256: try PatchBuildContentHasher.sha256(fileAt: outputURL)
                )
            )
            try PatchBuildRecordCodec.write(record, to: recordURL)
            completedUnitCount += 1
            report(.completed, message: "Dylib build completed.")
            return record
        } catch {
            for url in productURLs + [recordURL] {
                try? removeOutputArtifactIfPresent(at: url)
            }
            throw error
        }
    }

    private func compileSlice(
        _ architecture: BuildSliceArchitecture,
        project: PatchProject,
        resolution: BuildArchitectureResolution,
        probe: ToolchainArchitectureProbe,
        toolchain: AppleToolchain,
        sourceURL: URL,
        outputURL: URL,
        installName: String
    ) throws -> PatchBuildSliceRecord {
        let arguments = [
            "-arch", architecture.clangName,
            "-isysroot", toolchain.sdkPath,
            "-miphoneos-version-min=\(project.build.minimumIOSVersion)",
            project.build.enableARC ? "-fobjc-arc" : "-fno-objc-arc",
            "-fblocks",
            "-dynamiclib",
            "-Wall",
            "-Wextra",
            "-framework", "Foundation",
            "-framework", "UIKit",
            "-framework", "CoreGraphics",
            "-Wl,-install_name,\(installName)",
            sourceURL.path,
            "-o", outputURL.path,
        ]
        let invocation = BuildCommandInvocation(
            executablePath: toolchain.clangPath,
            arguments: arguments
        )
        let compilation = try commandRunner.run(invocation)
        guard compilation.terminationStatus == 0 else {
            throw PatchDylibBuilderError.compilerFailed(compilation)
        }
        guard isRegularFile(at: outputURL) else {
            throw PatchDylibBuilderError.compilerDidNotProduceOutput(outputURL.path)
        }

        let slices = try MachOInspector().inspect(at: outputURL)
        guard slices.count == 1, let slice = slices.first else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Compiled \(architecture.rawValue) output contains \(slices.count) slices; expected one."
            )
        }
        try validateBuiltSlice(
            slice,
            expectedArchitecture: architecture,
            resolution: resolution,
            probe: probe,
            minimumIOSVersion: project.build.minimumIOSVersion,
            installName: installName
        )
        return PatchBuildSliceRecord(
            architecture: architecture,
            cpuSubtype: slice.cpuSubtype,
            cpuSubtypeBase: slice.cpuSubtypeBase,
            cpuSubtypeCapabilities: slice.cpuSubtypeCapabilities,
            platform: slice.platform,
            minimumOSVersion: slice.minimumOSVersion ?? "",
            installName: slice.installName ?? "",
            outputPath: outputURL.path,
            compilation: compilation
        )
    }

    private func mergeUniversal(
        records: [PatchBuildSliceRecord],
        toolchain: AppleToolchain,
        outputURL: URL,
        minimumIOSVersion: String,
        installName: String
    ) throws -> BuildCommandExecution {
        guard records.map(\.architecture) == [.arm64, .arm64e] else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Universal output requires validated arm64 and arm64e slices in that order."
            )
        }
        let invocation = BuildCommandInvocation(
            executablePath: toolchain.lipoPath,
            arguments: [
                "-create",
                records[0].outputPath,
                records[1].outputPath,
                "-output",
                outputURL.path,
            ]
        )
        let execution = try commandRunner.run(invocation)
        guard execution.terminationStatus == 0 else {
            throw PatchDylibBuilderError.mergeFailed(execution)
        }
        guard isRegularFile(at: outputURL) else {
            throw PatchDylibBuilderError.compilerDidNotProduceOutput(outputURL.path)
        }

        let slices = try MachOInspector().inspect(at: outputURL)
        guard slices.count == 2 else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Merged universal output contains \(slices.count) slices; expected two."
            )
        }
        for record in records {
            guard
                let slice = slices.first(where: {
                    $0.architecture == record.architecture.machOArchitecture
                })
            else {
                throw PatchDylibBuilderError.outputValidationFailed(
                    "Merged output is missing its \(record.architecture.rawValue) slice."
                )
            }
            guard slice.cpuSubtype == record.cpuSubtype,
                slice.platform == .iPhoneOS,
                versionsEqual(slice.minimumOSVersion, minimumIOSVersion),
                slice.installName == installName
            else {
                throw PatchDylibBuilderError.outputValidationFailed(
                    "Merged \(record.architecture.rawValue) metadata differs from its validated thin slice."
                )
            }
        }
        return execution
    }

    private func compareExportedSymbols(
        records: [PatchBuildSliceRecord],
        toolchain: AppleToolchain
    ) throws -> [BuildCommandExecution] {
        guard records.map(\.architecture) == [.arm64, .arm64e] else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Exported-symbol comparison requires arm64 and arm64e thin slices."
            )
        }
        let executions = try records.map { record in
            let invocation = BuildCommandInvocation(
                executablePath: toolchain.nmPath,
                arguments: ["-g", "-U", "-j", record.outputPath]
            )
            let execution = try commandRunner.run(invocation)
            guard execution.terminationStatus == 0 else {
                throw PatchDylibBuilderError.symbolInspectionFailed(execution)
            }
            return execution
        }
        let symbolSets = executions.map { execution in
            Set(
                execution.standardOutput.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        guard symbolSets[0] == symbolSets[1] else {
            let missingFromArm64e = symbolSets[0].subtracting(symbolSets[1]).sorted()
            let missingFromArm64 = symbolSets[1].subtracting(symbolSets[0]).sorted()
            throw PatchDylibBuilderError.outputValidationFailed(
                "Thin slices export different symbols; missing from arm64e: \(missingFromArm64e), missing from arm64: \(missingFromArm64)."
            )
        }
        return executions
    }

    private func validateProbe(
        _ probe: ToolchainArchitectureProbe,
        resolution: BuildArchitectureResolution,
        minimumIOSVersion: String
    ) throws {
        guard probe.supported else {
            throw PatchDylibBuilderError.toolchainArchitectureUnsupported(probe)
        }
        guard probe.outputArchitecture == probe.requestedArchitecture.machOArchitecture else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Toolchain probe requested \(probe.requestedArchitecture.rawValue) but produced '\(probe.outputArchitecture?.rawValue ?? "unknown")'."
            )
        }
        guard probe.outputPlatform == .iPhoneOS else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Toolchain probe produced '\(probe.outputPlatform?.rawValue ?? "unknown")' instead of iPhoneOS."
            )
        }
        guard versionsEqual(probe.outputMinimumOSVersion, minimumIOSVersion) else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Toolchain probe deployment target '\(probe.outputMinimumOSVersion ?? "unknown")' does not match '\(minimumIOSVersion)'."
            )
        }
        try validateCPUSubtype(
            architecture: probe.requestedArchitecture,
            outputSubtype: probe.outputCPUSubtype,
            outputSubtypeBase: probe.outputCPUSubtypeBase,
            outputCapabilities: probe.outputCPUSubtypeCapabilities,
            resolution: resolution,
            context: "Toolchain probe"
        )
    }

    private func validateBuiltSlice(
        _ slice: MachOSlice,
        expectedArchitecture: BuildSliceArchitecture,
        resolution: BuildArchitectureResolution,
        probe: ToolchainArchitectureProbe,
        minimumIOSVersion: String,
        installName: String
    ) throws {
        guard slice.architecture == expectedArchitecture.machOArchitecture else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Clang requested \(expectedArchitecture.rawValue) but emitted '\(slice.architecture.rawValue)'."
            )
        }
        guard slice.fileType == .dynamicLibrary else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Compiled output is '\(slice.fileType.rawValue)' instead of a dynamic library."
            )
        }
        guard slice.platform == .iPhoneOS else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Compiled output targets '\(slice.platform.rawValue)' instead of iPhoneOS."
            )
        }
        guard versionsEqual(slice.minimumOSVersion, minimumIOSVersion) else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Compiled deployment target '\(slice.minimumOSVersion ?? "unknown")' does not match '\(minimumIOSVersion)'."
            )
        }
        guard slice.installName == installName else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Compiled install name '\(slice.installName ?? "none")' does not match '\(installName)'."
            )
        }
        guard slice.cpuSubtype == probe.outputCPUSubtype else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Compiled CPU subtype \(slice.cpuSubtype) differs from the toolchain probe subtype \(probe.outputCPUSubtype.map(String.init) ?? "unknown")."
            )
        }
        try validateCPUSubtype(
            architecture: expectedArchitecture,
            outputSubtype: slice.cpuSubtype,
            outputSubtypeBase: slice.cpuSubtypeBase,
            outputCapabilities: slice.cpuSubtypeCapabilities,
            resolution: resolution,
            context: "Compiled output"
        )
    }

    private func validateCPUSubtype(
        architecture: BuildSliceArchitecture,
        outputSubtype: Int32?,
        outputSubtypeBase: UInt32?,
        outputCapabilities: UInt32?,
        resolution: BuildArchitectureResolution,
        context: String
    ) throws {
        guard let outputSubtype, let outputSubtypeBase, let outputCapabilities else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "\(context) did not provide complete CPU subtype metadata."
            )
        }
        switch architecture {
        case .arm64:
            guard (outputSubtypeBase == 0 || outputSubtypeBase == 1), outputCapabilities == 0 else {
                throw PatchDylibBuilderError.outputValidationFailed(
                    "\(context) emitted unsupported arm64 CPU subtype \(outputSubtype)."
                )
            }
        case .arm64e:
            let abi = ArchitectureResolver.arm64eABI(
                architecture: .arm64e,
                cpuSubtype: outputSubtype
            )
            guard outputSubtypeBase == 2, abi?.generation == .versioned else {
                throw PatchDylibBuilderError.outputValidationFailed(
                    "\(context) emitted legacy or unknown arm64e CPU subtype \(outputSubtype)."
                )
            }
            if resolution.targetArchitecture == .arm64e,
                outputSubtype != resolution.targetCPUSubtype
            {
                throw PatchDylibBuilderError.outputValidationFailed(
                    "\(context) arm64e CPU subtype \(outputSubtype) does not exactly match target subtype \(resolution.targetCPUSubtype)."
                )
            }
        }
    }

    private func requiredProbe(
        for architecture: BuildSliceArchitecture,
        in probes: [ToolchainArchitectureProbe]
    ) throws -> ToolchainArchitectureProbe {
        guard let probe = probes.first(where: { $0.requestedArchitecture == architecture }) else {
            throw PatchDylibBuilderError.outputValidationFailed(
                "Missing toolchain capability probe for \(architecture.rawValue)."
            )
        }
        return probe
    }

    private func versionsEqual(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return normalizedVersion(lhs) == normalizedVersion(rhs)
    }

    private func normalizedVersion(_ value: String) -> [Int]? {
        var components = value.split(separator: ".").compactMap { Int($0) }
        guard !components.isEmpty,
            components.count == value.split(separator: ".").count
        else { return nil }
        while components.last == 0 { components.removeLast() }
        return components
    }

    private func removePreviousRegularFile(at url: URL) throws {
        let fileManager = FileManager.default
        if isSymbolicLink(at: url) {
            throw PatchDylibBuilderError.unsafeOutputPath(url.path)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }
        guard !isDirectory.boolValue else {
            throw PatchDylibBuilderError.outputCollision(url.path)
        }
        try fileManager.removeItem(at: url)
    }

    private func removeOutputArtifactIfPresent(at url: URL) throws {
        if isSymbolicLink(at: url) {
            try FileManager.default.removeItem(at: url)
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func isRegularFile(at url: URL) -> Bool {
        guard !isSymbolicLink(at: url) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

}

public enum PatchDylibBuilderError: Error, Equatable, LocalizedError, Sendable {
    case unsafeOutputPath(String)
    case outputCollision(String)
    case toolchainArchitectureUnsupported(ToolchainArchitectureProbe)
    case compilerFailed(BuildCommandExecution)
    case symbolInspectionFailed(BuildCommandExecution)
    case mergeFailed(BuildCommandExecution)
    case compilerDidNotProduceOutput(String)
    case outputValidationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeOutputPath(let path):
            "Build output must not replace a symbolic link: \(path)"
        case .outputCollision(let path):
            "Build output collides with a directory: \(path)"
        case .toolchainArchitectureUnsupported(let probe):
            "The selected Xcode toolchain cannot produce \(probe.requestedArchitecture.rawValue): \(probe.failureReason ?? "architecture probe failed")"
        case .compilerFailed(let execution):
            commandFailureDescription("Clang", execution)
        case .symbolInspectionFailed(let execution):
            commandFailureDescription("nm", execution)
        case .mergeFailed(let execution):
            commandFailureDescription("lipo", execution)
        case .compilerDidNotProduceOutput(let path):
            "The build command reported success but did not produce a regular dylib at: \(path)"
        case .outputValidationFailed(let message):
            "Built Mach-O validation failed: \(message)"
        }
    }

    private func commandFailureDescription(
        _ tool: String,
        _ execution: BuildCommandExecution
    ) -> String {
        let value =
            execution.standardError.isEmpty
            ? execution.standardOutput : execution.standardError
        let diagnostics = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = diagnostics.isEmpty ? "" : "\n\(diagnostics)"
        return
            "\(tool) failed with exit status \(execution.terminationStatus): \(execution.invocation.displayString)\(suffix)"
    }
}
