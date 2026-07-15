import Foundation
import MachPatchAnalyzer
import MachPatchBuilder
import MachPatchCore

protocol TargetLoading: Sendable {
    func loadTarget(at inputURL: URL) async throws -> LoadedTarget

    func loadAnalysis(
        at inputURL: URL,
        expectedSHA256: String,
        sliceIndex: Int
    ) async throws -> LoadedObjectiveCAnalysis
}

struct TargetLoader: TargetLoading {
    func loadTarget(at inputURL: URL) async throws -> LoadedTarget {
        try await Task.detached(priority: .userInitiated) {
            let hasSecurityScope = inputURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    inputURL.stopAccessingSecurityScopedResource()
                }
            }

            try Task.checkCancellation()
            return try InputResolver().withResolvedTarget(at: inputURL) { target in
                try Task.checkCancellation()
                let inspection = try MachOInspector().inspect(target)
                let architectureReport = ArchitectureResolver.report(for: inspection.slices)
                let initialAnalysis = initialAnalysis(
                    target: target,
                    architectureReport: architectureReport
                )
                return LoadedTarget(
                    inputURL: inputURL,
                    target: target,
                    inspection: inspection,
                    architectureReport: architectureReport,
                    iconData: TargetIconLoader().loadIconData(for: target),
                    analysisState: initialAnalysis.state,
                    patchabilityReport: initialAnalysis.report
                )
            }
        }.value
    }

    func loadAnalysis(
        at inputURL: URL,
        expectedSHA256: String,
        sliceIndex: Int
    ) async throws -> LoadedObjectiveCAnalysis {
        try await Task.detached(priority: .userInitiated) {
            let hasSecurityScope = inputURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    inputURL.stopAccessingSecurityScopedResource()
                }
            }

            return try InputResolver().withResolvedTarget(at: inputURL) { target in
                try Task.checkCancellation()
                guard target.sha256 == expectedSHA256 else {
                    throw TargetLoadingError.targetChanged
                }
                let slices = try MachOInspector().inspect(target).slices
                let report = ArchitectureResolver.report(for: slices)
                guard
                    report.slices.contains(where: {
                        $0.index == sliceIndex && $0.supportedForPatching
                    })
                else {
                    throw TargetLoadingError.unsupportedSlice(sliceIndex)
                }
                let analysis = try ObjectiveCAnalyzer().analyze(target, sliceIndex: sliceIndex)
                return LoadedObjectiveCAnalysis(
                    analysis: analysis,
                    patchabilityReport: ObjectiveCPatchabilityAnalyzer.report(
                        for: analysis.metadata
                    )
                )
            }
        }.value
    }

    private func initialAnalysis(
        target: ResolvedTarget,
        architectureReport: TargetArchitectureReport
    ) -> (state: TargetAnalysisState, report: ObjectiveCPatchabilityReport?) {
        let supportedSlices = architectureReport.slices.filter(\.supportedForPatching)
        guard !supportedSlices.isEmpty else {
            return (.unavailable(architectureReport.automaticReason), nil)
        }
        guard supportedSlices.count == 1, let slice = supportedSlices.first else {
            return (.requiresSliceSelection, nil)
        }

        do {
            let analysis = try ObjectiveCAnalyzer().analyze(target, sliceIndex: slice.index)
            return (
                .loaded(analysis),
                ObjectiveCPatchabilityAnalyzer.report(for: analysis.metadata)
            )
        } catch {
            return (.failed(sliceIndex: slice.index, message: error.localizedDescription), nil)
        }
    }
}

enum TargetLoadingError: Error, Equatable, LocalizedError, Sendable {
    case targetChanged
    case unsupportedSlice(Int)

    var errorDescription: String? {
        switch self {
        case .targetChanged:
            "The target changed after it was opened. Open it again before analyzing classes."
        case .unsupportedSlice(let sliceIndex):
            "Slice \(sliceIndex) is unavailable or unsupported for patching."
        }
    }
}
