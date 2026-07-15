import Foundation
import MachPatchAnalyzer
import MachPatchCore

public struct LiveContainerVerifier: Sendable {
    private let inspector: MachOInspector
    private let commandRunner: any VerificationCommandRunning
    private let configuredTools: VerificationTools?

    public init(
        inspector: MachOInspector = MachOInspector(),
        commandRunner: any VerificationCommandRunning = ProcessVerificationCommandRunner(),
        tools: VerificationTools? = nil
    ) {
        self.inspector = inspector
        self.commandRunner = commandRunner
        configuredTools = tools
    }

    public func verify(
        dylibURL: URL,
        targetInspection: MachOInspection? = nil
    ) throws -> DylibVerificationReport {
        let dylibURL = dylibURL.standardizedFileURL
        try validateInput(at: dylibURL)

        let slices = try inspector.inspect(at: dylibURL)
        let tools =
            try configuredTools
            ?? VerificationToolDiscoverer(commandRunner: commandRunner).discover()
        var checks: [VerificationCheck] = []

        checks.append(contentsOf: fileTypeChecks(for: slices))
        checks.append(contentsOf: architectureChecks(for: slices))
        checks.append(contentsOf: platformChecks(for: slices))
        checks.append(contentsOf: deploymentPresenceChecks(for: slices))
        checks.append(contentsOf: installNameChecks(for: slices, dylibURL: dylibURL))

        let lipo = try commandRunner.run(
            VerificationCommandInvocation(
                executablePath: tools.lipoPath,
                arguments: ["-archs", dylibURL.path]
            )
        )
        let lipoArchitectures = Self.parseLipoArchitectures(lipo.standardOutput)
        checks.append(lipoCheck(execution: lipo, architectures: lipoArchitectures, slices: slices))

        let dependencies = dependencyAssessments(for: slices, dylibURL: dylibURL)
        checks.append(contentsOf: dependencyChecks(for: dependencies))

        let allowedSymbolProviders = Set<String>(
            dependencies.compactMap { dependency in
                guard
                    dependency.classification == .appleSystem
                        || dependency.classification == .includedAdjacent
                else { return nil }
                return Self.symbolProviderName(for: dependency.library.path)
            }
        )
        var nmExecutions: [VerificationCommandExecution] = []
        var unresolvedSymbols: [UnresolvedSymbol] = []
        let nmArchitectures = Set(slices.map { Self.lipoName(for: $0.architecture) }).sorted()
        for architecture in nmArchitectures {
            let execution = try commandRunner.run(
                VerificationCommandInvocation(
                    executablePath: tools.nmPath,
                    arguments: ["-arch", architecture, "-u", "-m", dylibURL.path]
                )
            )
            nmExecutions.append(execution)
            if execution.terminationStatus == 0 {
                unresolvedSymbols.append(
                    contentsOf: UnresolvedSymbolParser.parse(
                        execution.standardOutput,
                        defaultArchitecture: architecture,
                        allowedProviders: allowedSymbolProviders
                    )
                )
            }
        }
        checks.append(symbolCheck(executions: nmExecutions, symbols: unresolvedSymbols))

        let forbiddenPaths = try BinaryPathScanner().scan(at: dylibURL)
        checks.append(forbiddenPathCheck(forbiddenPaths))

        checks.append(
            targetCompatibilityCheck(
                dylibSlices: slices,
                targetInspection: targetInspection
            )
        )
        checks.append(
            deploymentCompatibilityCheck(
                dylibSlices: slices,
                targetInspection: targetInspection
            )
        )

        return DylibVerificationReport(
            dylibPath: dylibURL.path,
            target: targetInspection?.target,
            slices: slices,
            targetSlices: targetInspection?.slices ?? [],
            lipoArchitectures: lipoArchitectures,
            dependencies: dependencies,
            unresolvedSymbols: unresolvedSymbols,
            forbiddenPaths: forbiddenPaths,
            checks: checks,
            toolExecutions: [lipo] + nmExecutions
        )
    }

    private func validateInput(at url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw LiveContainerVerificationError.unreadableDylib(error.localizedDescription)
        }
        guard values.isSymbolicLink != true else {
            throw LiveContainerVerificationError.symbolicLinkInput(url.path)
        }
        guard values.isRegularFile == true else {
            throw LiveContainerVerificationError.notRegularFile(url.path)
        }
    }

    private func fileTypeChecks(for slices: [MachOSlice]) -> [VerificationCheck] {
        slices.map { slice in
            guard slice.fileType == .dynamicLibrary else {
                return VerificationCheck(
                    code: .fileType,
                    status: .failed,
                    message:
                        "Slice \(slice.index) is \(slice.fileType.rawValue), not a dynamic library.",
                    sliceIndex: slice.index
                )
            }
            return VerificationCheck(
                code: .fileType,
                status: .passed,
                message: "Slice \(slice.index) is a dynamic library.",
                sliceIndex: slice.index
            )
        }
    }

    private func architectureChecks(for slices: [MachOSlice]) -> [VerificationCheck] {
        slices.map { slice in
            let detail =
                "CPU subtype \(slice.cpuSubtype) (base \(slice.cpuSubtypeBase), capabilities \(slice.cpuSubtypeCapabilities))"
            switch slice.architecture {
            case .arm64 where slice.cpuSubtype == 0:
                return VerificationCheck(
                    code: .architecture,
                    status: .passed,
                    message: "Slice \(slice.index) is supported ordinary arm64.",
                    sliceIndex: slice.index,
                    evidence: [detail]
                )
            case .arm64e where slice.cpuSubtypeBase == 2:
                return VerificationCheck(
                    code: .architecture,
                    status: .passed,
                    message: "Slice \(slice.index) is supported versioned arm64e.",
                    sliceIndex: slice.index,
                    evidence: [detail]
                )
            case .arm64eLegacy:
                return VerificationCheck(
                    code: .architecture,
                    status: .failed,
                    message: "Slice \(slice.index) uses the unsupported legacy arm64e ABI.",
                    sliceIndex: slice.index,
                    evidence: [detail]
                )
            default:
                return VerificationCheck(
                    code: .architecture,
                    status: .failed,
                    message:
                        "Slice \(slice.index) has unsupported architecture \(slice.architecture.rawValue).",
                    sliceIndex: slice.index,
                    evidence: [detail]
                )
            }
        }
    }

    private func platformChecks(for slices: [MachOSlice]) -> [VerificationCheck] {
        slices.map { slice in
            guard slice.platform == .iPhoneOS else {
                return VerificationCheck(
                    code: .platform,
                    status: .failed,
                    message:
                        "Slice \(slice.index) targets \(slice.platform.rawValue), not iPhoneOS.",
                    sliceIndex: slice.index
                )
            }
            return VerificationCheck(
                code: .platform,
                status: .passed,
                message: "Slice \(slice.index) targets iPhoneOS.",
                sliceIndex: slice.index
            )
        }
    }

    private func deploymentPresenceChecks(for slices: [MachOSlice]) -> [VerificationCheck] {
        slices.map { slice in
            guard let version = slice.minimumOSVersion else {
                return VerificationCheck(
                    code: .deploymentTarget,
                    status: .failed,
                    message: "Slice \(slice.index) does not declare a minimum iOS version.",
                    sliceIndex: slice.index
                )
            }
            return VerificationCheck(
                code: .deploymentTarget,
                status: .passed,
                message: "Slice \(slice.index) declares minimum iOS \(version).",
                sliceIndex: slice.index
            )
        }
    }

    private func installNameChecks(
        for slices: [MachOSlice],
        dylibURL: URL
    ) -> [VerificationCheck] {
        let expected = "@rpath/\(dylibURL.lastPathComponent)"
        return slices.map { slice in
            guard let installName = slice.installName else {
                return VerificationCheck(
                    code: .installName,
                    status: .failed,
                    message: "Slice \(slice.index) has no LC_ID_DYLIB install name.",
                    sliceIndex: slice.index
                )
            }
            guard installName == expected else {
                let developmentPath =
                    installName.hasPrefix("/Users/")
                    || installName.hasPrefix("/Volumes/")
                return VerificationCheck(
                    code: .installName,
                    status: .failed,
                    message: developmentPath
                        ? "Slice \(slice.index) contains an absolute development-machine install name."
                        : "Slice \(slice.index) install name is not the required @rpath identity.",
                    sliceIndex: slice.index,
                    evidence: ["expected: \(expected)", "actual: \(installName)"]
                )
            }
            return VerificationCheck(
                code: .installName,
                status: .passed,
                message: "Slice \(slice.index) install name is \(expected).",
                sliceIndex: slice.index
            )
        }
    }

    private func lipoCheck(
        execution: VerificationCommandExecution,
        architectures: [String],
        slices: [MachOSlice]
    ) -> VerificationCheck {
        guard execution.terminationStatus == 0 else {
            return VerificationCheck(
                code: .lipoAgreement,
                status: .failed,
                message: "lipo could not read the dylib architecture list.",
                evidence: diagnosticEvidence(for: execution)
            )
        }
        let native = slices.map { Self.lipoName(for: $0.architecture) }.sorted()
        guard !architectures.isEmpty, architectures.sorted() == native else {
            return VerificationCheck(
                code: .lipoAgreement,
                status: .failed,
                message: "lipo and native Mach-O parsing disagree about the architecture list.",
                evidence: [
                    "native: \(native.joined(separator: ", "))",
                    "lipo: \(architectures.joined(separator: ", "))",
                ]
            )
        }
        return VerificationCheck(
            code: .lipoAgreement,
            status: .passed,
            message: "lipo and native parsing agree: \(native.joined(separator: ", "))."
        )
    }

    private func dependencyAssessments(
        for slices: [MachOSlice],
        dylibURL: URL
    ) -> [DependencyAssessment] {
        slices.flatMap { slice in
            slice.linkedLibraries.map { library in
                let assessment = CompatibilityPolicy.assessDependency(
                    library.path,
                    relativeTo: dylibURL.deletingLastPathComponent()
                )
                return DependencyAssessment(
                    sliceIndex: slice.index,
                    library: library,
                    classification: assessment.classification,
                    resolvedPath: assessment.resolvedPath
                )
            }
        }
    }

    private func dependencyChecks(
        for dependencies: [DependencyAssessment]
    ) -> [VerificationCheck] {
        let failures = dependencies.filter {
            $0.classification == .forbiddenJailbreak
                || $0.classification == .unsupportedExternal
        }
        guard failures.isEmpty else {
            return failures.map { dependency in
                VerificationCheck(
                    code: .dependency,
                    status: .failed,
                    message: dependency.classification == .forbiddenJailbreak
                        ? "A forbidden jailbreak dependency is linked."
                        : "A non-system dependency is not included beside the output.",
                    sliceIndex: dependency.sliceIndex,
                    evidence: [dependency.library.path]
                )
            }
        }
        return [
            VerificationCheck(
                code: .dependency,
                status: .passed,
                message: dependencies.isEmpty
                    ? "No linked dylib dependencies were declared."
                    : "All linked dependencies are Apple system libraries or included beside the output."
            )
        ]
    }

    private func symbolCheck(
        executions: [VerificationCommandExecution],
        symbols: [UnresolvedSymbol]
    ) -> VerificationCheck {
        let failedExecutions = executions.filter { $0.terminationStatus != 0 }
        guard failedExecutions.isEmpty else {
            return VerificationCheck(
                code: .unresolvedSymbols,
                status: .failed,
                message: "nm could not inspect unresolved symbols for every dylib slice.",
                evidence: failedExecutions.flatMap(diagnosticEvidence)
            )
        }
        let unexpected = symbols.filter { $0.classification == .unexpectedExternal }
        guard unexpected.isEmpty else {
            return VerificationCheck(
                code: .unresolvedSymbols,
                status: .failed,
                message: "Unexpected unresolved symbols were found.",
                evidence: unexpected.prefix(50).map { symbol in
                    if let provider = symbol.provider {
                        return "\(symbol.name) from \(provider)"
                    }
                    return symbol.name
                }
            )
        }
        return VerificationCheck(
            code: .unresolvedSymbols,
            status: .passed,
            message:
                "All \(symbols.count) unresolved symbols are expected Apple runtime or framework symbols."
        )
    }

    private func forbiddenPathCheck(
        _ paths: [ForbiddenPathFinding]
    ) -> VerificationCheck {
        guard paths.isEmpty else {
            return VerificationCheck(
                code: .forbiddenFilesystemPath,
                status: .failed,
                message: "Forbidden jailbreak filesystem references were embedded in the dylib.",
                evidence: paths.prefix(50).map { "\($0.marker): \($0.value)" }
            )
        }
        return VerificationCheck(
            code: .forbiddenFilesystemPath,
            status: .passed,
            message: "No forbidden jailbreak filesystem references were found."
        )
    }

    private func targetCompatibilityCheck(
        dylibSlices: [MachOSlice],
        targetInspection: MachOInspection?
    ) -> VerificationCheck {
        guard let targetInspection else {
            return VerificationCheck(
                code: .targetCompatibility,
                status: .warning,
                message:
                    "No target was supplied; target architecture compatibility was not checked."
            )
        }
        let matches = compatiblePairs(
            dylibSlices: dylibSlices,
            targetSlices: targetInspection.slices
        )
        guard !matches.isEmpty else {
            return VerificationCheck(
                code: .targetCompatibility,
                status: .failed,
                message:
                    "The dylib has no architecture and CPU subtype compatible with the selected target.",
                evidence: [
                    "dylib: \(architectureEvidence(dylibSlices))",
                    "target: \(architectureEvidence(targetInspection.slices))",
                ]
            )
        }
        return VerificationCheck(
            code: .targetCompatibility,
            status: .passed,
            message: "The dylib has a compatible target slice.",
            evidence: matches.map {
                "dylib slice \($0.0.index) matches target slice \($0.1.index): \($0.0.architecture.rawValue), subtype \($0.0.cpuSubtype)"
            }
        )
    }

    private func deploymentCompatibilityCheck(
        dylibSlices: [MachOSlice],
        targetInspection: MachOInspection?
    ) -> VerificationCheck {
        guard let targetInspection else {
            return VerificationCheck(
                code: .deploymentTarget,
                status: .warning,
                message: "No target was supplied; deployment compatibility was not checked."
            )
        }
        let matches = compatiblePairs(
            dylibSlices: dylibSlices,
            targetSlices: targetInspection.slices
        )
        let hostMinimum = targetInspection.target.minimumOSVersion.flatMap { text in
            NumericVersion(text).map { (text, $0) }
        }
        let comparisons = matches.compactMap { pair -> DeploymentComparison? in
            guard let dylibText = pair.0.minimumOSVersion,
                let dylibVersion = NumericVersion(dylibText)
            else { return nil }

            let imageMinimum = pair.1.minimumOSVersion.flatMap { text in
                NumericVersion(text).map { (text, $0) }
            }
            let effectiveMinimum: (String, NumericVersion)
            switch (hostMinimum, imageMinimum) {
            case (.some(let host), .some(let image)):
                effectiveMinimum = host.1 >= image.1 ? host : image
            case (.some(let host), .none):
                effectiveMinimum = host
            case (.none, .some(let image)):
                effectiveMinimum = image
            case (.none, .none):
                return nil
            }

            return DeploymentComparison(
                dylibMinimum: dylibText,
                imageMinimum: imageMinimum?.0,
                hostMinimum: hostMinimum?.0,
                effectiveMinimum: effectiveMinimum.0,
                isCompatible: dylibVersion <= effectiveMinimum.1
            )
        }
        if comparisons.contains(where: \.isCompatible) {
            return VerificationCheck(
                code: .deploymentTarget,
                status: .passed,
                message: "The dylib deployment target is compatible with a matching target slice.",
                evidence: comparisons.map(\.evidence)
            )
        }
        if !comparisons.isEmpty {
            return VerificationCheck(
                code: .deploymentTarget,
                status: .failed,
                message: "The dylib requires a newer iOS version than the matching target slice.",
                evidence: comparisons.map(\.evidence)
            )
        }
        return VerificationCheck(
            code: .deploymentTarget,
            status: .warning,
            message:
                "Deployment compatibility could not be compared because a matching version value was unavailable."
        )
    }

    private struct DeploymentComparison {
        let dylibMinimum: String
        let imageMinimum: String?
        let hostMinimum: String?
        let effectiveMinimum: String
        let isCompatible: Bool

        var evidence: String {
            var fields = ["dylib iOS \(dylibMinimum)"]
            if let imageMinimum {
                fields.append("target image iOS \(imageMinimum)")
            }
            if let hostMinimum {
                fields.append("host iOS \(hostMinimum)")
            }
            fields.append("effective iOS \(effectiveMinimum)")
            return fields.joined(separator: ", ")
        }
    }

    private func compatiblePairs(
        dylibSlices: [MachOSlice],
        targetSlices: [MachOSlice]
    ) -> [(MachOSlice, MachOSlice)] {
        dylibSlices.flatMap { dylibSlice in
            targetSlices.compactMap { targetSlice in
                guard targetSlice.platform == .iPhoneOS,
                    dylibSlice.architecture == targetSlice.architecture,
                    dylibSlice.cpuSubtype == targetSlice.cpuSubtype
                else { return nil }
                return (dylibSlice, targetSlice)
            }
        }
    }

    private func architectureEvidence(_ slices: [MachOSlice]) -> String {
        slices.map {
            "\($0.architecture.rawValue)/\($0.cpuSubtype)/\($0.platform.rawValue)"
        }.joined(separator: ", ")
    }

    private func diagnosticEvidence(
        for execution: VerificationCommandExecution
    ) -> [String] {
        let diagnostics = execution.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return diagnostics.isEmpty
            ? ["exit status \(execution.terminationStatus)"]
            : ["exit status \(execution.terminationStatus)", diagnostics]
    }

    static func parseLipoArchitectures(_ output: String) -> [String] {
        let known = Set([
            "arm64", "arm64e", "arm64_32", "armv7", "armv7s", "x86_64",
        ])
        return output.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            let value = token.trimmingCharacters(in: CharacterSet(charactersIn: ":,"))
            return known.contains(value) ? value : nil
        }
    }

    private static func lipoName(for architecture: MachOArchitecture) -> String {
        switch architecture {
        case .arm64: "arm64"
        case .arm64e, .arm64eLegacy: "arm64e"
        case .arm6432: "arm64_32"
        case .armv7: "armv7"
        case .armv7s: "armv7s"
        case .x8664: "x86_64"
        case .unknown: "unknown"
        }
    }

    private static func symbolProviderName(for dependencyPath: String) -> String {
        let filename = URL(filePath: dependencyPath).lastPathComponent
        if filename.hasPrefix("lib"), let period = filename.firstIndex(of: ".") {
            return String(filename[..<period])
        }
        return filename
    }
}

public enum LiveContainerVerificationError: Error, Equatable, LocalizedError, Sendable {
    case unreadableDylib(String)
    case symbolicLinkInput(String)
    case notRegularFile(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableDylib(let reason):
            "The dylib could not be read: \(reason)"
        case .symbolicLinkInput(let path):
            "The dylib input must not be a symbolic link: \(path)"
        case .notRegularFile(let path):
            "The dylib input is not a regular file: \(path)"
        }
    }
}

private struct NumericVersion: Comparable {
    let components: [Int]

    init?(_ value: String) {
        let values = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !values.isEmpty,
            values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        components = values.compactMap { Int($0) }
        guard components.count == values.count else { return nil }
    }

    static func < (lhs: NumericVersion, rhs: NumericVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
