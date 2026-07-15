import Foundation
import MachPatchCore

public enum AnalyzedPatchProjectValidator {
    public static func selectedSliceIndex(
        for project: PatchProject,
        in target: ResolvedTarget
    ) throws -> Int {
        let slices = try MachOInspector().inspect(at: target.executableURL)
        let matches = slices.filter {
            $0.architecture == project.target.selectedSlice.architecture
                && $0.cpuSubtype == project.target.selectedSlice.cpuSubtype
        }
        guard !matches.isEmpty else {
            throw AnalyzedPatchProjectValidationError.selectedSliceNotFound(
                project.target.selectedSlice.architecture,
                project.target.selectedSlice.cpuSubtype
            )
        }
        guard matches.count == 1, let match = matches.first else {
            throw AnalyzedPatchProjectValidationError.ambiguousSelectedSlice(
                project.target.selectedSlice.architecture,
                project.target.selectedSlice.cpuSubtype
            )
        }
        return match.index
    }

    public static func validate(
        _ project: PatchProject,
        against analysis: ObjectiveCAnalysis
    ) throws -> PatchProjectValidationReport {
        let slices = try MachOInspector().inspect(at: analysis.target.executableURL)
        guard slices.indices.contains(analysis.sliceIndex) else {
            throw ObjectiveCAnalyzerError.sliceIndexOutOfRange(analysis.sliceIndex)
        }
        return validate(project, against: analysis, selectedSlice: slices[analysis.sliceIndex])
    }

    public static func validate(
        _ project: PatchProject,
        against analysis: ObjectiveCAnalysis,
        selectedSlice: MachOSlice
    ) -> PatchProjectValidationReport {
        let base = PatchProjectValidator.validate(project)
        var errors = base.errors
        var warnings = base.warnings

        appendTargetIdentityIssues(
            project: project,
            analysis: analysis,
            slice: selectedSlice,
            errors: &errors,
            warnings: &warnings
        )
        for patch in project.patches {
            appendMethodIssues(
                patch: patch,
                metadata: analysis.metadata,
                errors: &errors
            )
        }
        return PatchProjectValidationReport(errors: errors, warnings: warnings)
    }

    private static func appendTargetIdentityIssues(
        project: PatchProject,
        analysis: ObjectiveCAnalysis,
        slice: MachOSlice,
        errors: inout [PatchProjectValidationIssue],
        warnings: inout [PatchProjectValidationIssue]
    ) {
        if project.target.executableSHA256.lowercased() != analysis.target.sha256.lowercased() {
            warnings.append(
                issue(
                    .targetHashMismatch,
                    "The selected binary differs from the executable recorded by the project."
                )
            )
        }
        if project.target.executableName != analysis.target.executableName {
            warnings.append(
                issue(
                    .targetExecutableNameMismatch,
                    "Executable name changed from '\(project.target.executableName)' to '\(analysis.target.executableName)'."
                )
            )
        }
        if let expectedBundleIdentifier = project.target.bundleIdentifier,
            expectedBundleIdentifier != analysis.target.bundleIdentifier
        {
            warnings.append(
                issue(
                    .targetBundleIdentifierMismatch,
                    "Bundle identifier changed from '\(expectedBundleIdentifier)' to '\(analysis.target.bundleIdentifier ?? "(none)")'."
                )
            )
        }
        if let expectedMinimumVersion = project.target.minimumIOSVersion,
            expectedMinimumVersion != slice.minimumOSVersion
        {
            warnings.append(
                issue(
                    .targetMinimumIOSVersionMismatch,
                    "Minimum iOS version changed from '\(expectedMinimumVersion)' to '\(slice.minimumOSVersion ?? "(unavailable)")'."
                )
            )
        }
        if project.target.selectedSlice.architecture != analysis.architecture {
            errors.append(
                issue(
                    .targetArchitectureMismatch,
                    "Selected architecture is '\(project.target.selectedSlice.architecture.rawValue)', but the analyzed slice is '\(analysis.architecture.rawValue)'."
                )
            )
        }
        if project.target.selectedSlice.cpuSubtype != slice.cpuSubtype {
            errors.append(
                issue(
                    .targetCPUSubtypeMismatch,
                    "Selected CPU subtype is \(project.target.selectedSlice.cpuSubtype), but the analyzed slice is \(slice.cpuSubtype)."
                )
            )
        }
    }

    private static func appendMethodIssues(
        patch: MethodPatch,
        metadata: ObjectiveCMetadata,
        errors: inout [PatchProjectValidationIssue]
    ) {
        guard ObjectiveCMethodCatalog.ownerClassNames(in: metadata).contains(patch.className) else {
            errors.append(
                issue(
                    .classNotFound,
                    "Objective-C class was not found: \(patch.className)",
                    patchID: patch.id
                )
            )
            return
        }

        let method = ObjectiveCMethodCatalog.method(
            forClassNamed: patch.className,
            kind: patch.methodKind,
            selector: patch.selector,
            in: metadata
        )
        let oppositeKind: ObjectiveCMethodKind =
            patch.methodKind == .instance ? .class : .instance

        guard let method else {
            let code: PatchProjectValidationCode =
                ObjectiveCMethodCatalog.method(
                    forClassNamed: patch.className,
                    kind: oppositeKind,
                    selector: patch.selector,
                    in: metadata
                ) == nil ? .methodNotFound : .methodKindMismatch
            let marker = patch.methodKind == .instance ? "-" : "+"
            errors.append(
                issue(
                    code,
                    code == .methodKindMismatch
                        ? "Selector exists on \(patch.className), but not as a \(patch.methodKind.rawValue) method."
                        : "Method was not found: \(marker)[\(patch.className) \(patch.selector)]",
                    patchID: patch.id
                )
            )
            return
        }

        guard !method.hasConflictingTypeEncodings else {
            errors.append(
                issue(
                    .conflictingMethodTypeEncodings,
                    "Method declarations disagree on the runtime type encoding: \(method.conflictingTypeEncodings.joined(separator: ", ")).",
                    patchID: patch.id
                )
            )
            return
        }

        guard method.typeEncoding == patch.expectedTypeEncoding else {
            errors.append(
                issue(
                    .typeEncodingChanged,
                    "Type encoding changed from '\(patch.expectedTypeEncoding)' to '\(method.typeEncoding ?? "(unavailable)")'.",
                    patchID: patch.id
                )
            )
            return
        }
    }

    private static func issue(
        _ code: PatchProjectValidationCode,
        _ message: String,
        patchID: String? = nil
    ) -> PatchProjectValidationIssue {
        PatchProjectValidationIssue(code: code, message: message, patchID: patchID)
    }
}

public enum AnalyzedPatchProjectValidationError: Error, Equatable, LocalizedError, Sendable {
    case selectedSliceNotFound(MachOArchitecture, Int32)
    case ambiguousSelectedSlice(MachOArchitecture, Int32)

    public var errorDescription: String? {
        switch self {
        case .selectedSliceNotFound(let architecture, let cpuSubtype):
            "Target does not contain the selected \(architecture.rawValue) CPU subtype \(cpuSubtype) slice."
        case .ambiguousSelectedSlice(let architecture, let cpuSubtype):
            "Target contains more than one \(architecture.rawValue) CPU subtype \(cpuSubtype) slice."
        }
    }
}
