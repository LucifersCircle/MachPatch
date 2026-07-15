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
        let base = PatchProjectValidator.validate(project)
        let slices = try MachOInspector().inspect(at: analysis.target.executableURL)
        guard slices.indices.contains(analysis.sliceIndex) else {
            throw ObjectiveCAnalyzerError.sliceIndexOutOfRange(analysis.sliceIndex)
        }
        let slice = slices[analysis.sliceIndex]
        var errors = base.errors
        var warnings = base.warnings

        appendTargetIdentityIssues(
            project: project,
            analysis: analysis,
            slice: slice,
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
        guard let objectiveCClass = metadata.classes.first(where: { $0.name == patch.className })
        else {
            errors.append(
                issue(
                    .classNotFound,
                    "Objective-C class was not found: \(patch.className)",
                    patchID: patch.id
                )
            )
            return
        }

        let selectedMethods =
            patch.methodKind == .instance
            ? objectiveCClass.instanceMethods : objectiveCClass.classMethods
        let oppositeMethods =
            patch.methodKind == .instance
            ? objectiveCClass.classMethods : objectiveCClass.instanceMethods

        guard let method = selectedMethods.first(where: { $0.selector == patch.selector }) else {
            let code: PatchProjectValidationCode =
                oppositeMethods.contains {
                    $0.selector == patch.selector
                } ? .methodKindMismatch : .methodNotFound
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
