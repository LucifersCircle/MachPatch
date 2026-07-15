import Foundation
import MachPatchAnalyzer
import MachPatchBuilder
import MachPatchCore

protocol TargetLoading: Sendable {
    func loadTarget(at inputURL: URL) async throws -> LoadedTarget

    func loadAnalysis(
        at inputURL: URL,
        expectedHostSHA256: String,
        imageID: String,
        expectedImageSHA256: String,
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
                if let issue = imageFileTypeIssue(
                    image: target.primaryImage,
                    slices: inspection.slices
                ) {
                    throw TargetLoadingError.incompatibleImageFileType(
                        target.primaryImage.executableName,
                        issue
                    )
                }
                let architectureReport = ArchitectureResolver.report(for: inspection.slices)
                let images = inspectImages(
                    in: target,
                    primaryInspection: inspection,
                    primaryArchitectureReport: architectureReport
                )
                let initialAnalysis = initialAnalysis(
                    target: target,
                    architectureReport: architectureReport
                )
                return LoadedTarget(
                    inputURL: inputURL,
                    target: target,
                    inspection: inspection,
                    architectureReport: architectureReport,
                    images: images,
                    iconData: TargetIconLoader().loadIconData(for: target),
                    analysisState: initialAnalysis.state,
                    patchabilityReport: initialAnalysis.report,
                    classBrowserTargets: initialAnalysis.classBrowserTargets
                )
            }
        }.value
    }

    private func inspectImages(
        in target: ResolvedTarget,
        primaryInspection: MachOInspection,
        primaryArchitectureReport: TargetArchitectureReport
    ) -> [LoadedTargetImage] {
        target.images.enumerated().map { index, image in
            if index == 0 {
                return LoadedTargetImage(
                    image: image,
                    inspectionState: .available(
                        slices: primaryInspection.slices,
                        architectureReport: primaryArchitectureReport
                    )
                )
            }

            do {
                let slices = try MachOInspector().inspect(at: image.executableURL)
                if let issue = imageFileTypeIssue(image: image, slices: slices) {
                    return LoadedTargetImage(
                        image: image,
                        inspectionState: .failed(issue)
                    )
                }
                return LoadedTargetImage(
                    image: image,
                    inspectionState: .available(
                        slices: slices,
                        architectureReport: ArchitectureResolver.report(for: slices)
                    )
                )
            } catch {
                return LoadedTargetImage(
                    image: image,
                    inspectionState: .failed(error.localizedDescription)
                )
            }
        }
    }

    private func imageFileTypeIssue(
        image: ResolvedImage,
        slices: [MachOSlice]
    ) -> String? {
        let expectedType: MachOFileType? =
            switch image.kind {
            case .mainExecutable, .appExtension:
                .executable
            case .dynamicFramework, .standaloneFramework:
                .dynamicLibrary
            case .standaloneMachO:
                nil
            }
        guard let expectedType,
            let mismatched = slices.first(where: { $0.fileType != expectedType })
        else { return nil }
        return
            "Expected a \(expectedType.rawValue) image, but slice \(mismatched.index) is \(mismatched.fileType.rawValue)."
    }

    func loadAnalysis(
        at inputURL: URL,
        expectedHostSHA256: String,
        imageID: String,
        expectedImageSHA256: String,
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
                guard target.sha256 == expectedHostSHA256 else {
                    throw TargetLoadingError.targetChanged
                }
                guard let image = target.images.first(where: { $0.id == imageID }) else {
                    throw TargetLoadingError.imageNotFound(imageID)
                }
                guard image.sha256 == expectedImageSHA256 else {
                    throw TargetLoadingError.imageChanged(image.executableName)
                }
                let slices = try MachOInspector().inspect(at: image.executableURL)
                let report = ArchitectureResolver.report(for: slices)
                guard
                    report.slices.contains(where: {
                        $0.index == sliceIndex && $0.supportedForPatching
                    })
                else {
                    throw TargetLoadingError.unsupportedSlice(sliceIndex)
                }
                let analysis = try ObjectiveCAnalyzer().analyze(
                    target,
                    image: image,
                    sliceIndex: sliceIndex
                )
                return LoadedObjectiveCAnalysis(
                    analysis: analysis,
                    patchabilityReport: ObjectiveCPatchabilityAnalyzer.report(
                        for: analysis.metadata
                    ),
                    classBrowserTargets: ObjectiveCClassBrowserCatalog.targets(for: analysis)
                )
            }
        }.value
    }

    private func initialAnalysis(
        target: ResolvedTarget,
        architectureReport: TargetArchitectureReport
    ) -> (
        state: TargetAnalysisState,
        report: ObjectiveCPatchabilityReport?,
        classBrowserTargets: [ObjectiveCClassBrowserTarget]
    ) {
        let supportedSlices = architectureReport.slices.filter(\.supportedForPatching)
        guard !supportedSlices.isEmpty else {
            return (.unavailable(architectureReport.automaticReason), nil, [])
        }
        guard supportedSlices.count == 1, let slice = supportedSlices.first else {
            return (.requiresSliceSelection, nil, [])
        }

        do {
            let analysis = try ObjectiveCAnalyzer().analyze(target, sliceIndex: slice.index)
            return (
                .loaded(analysis),
                ObjectiveCPatchabilityAnalyzer.report(for: analysis.metadata),
                ObjectiveCClassBrowserCatalog.targets(for: analysis)
            )
        } catch {
            return (
                .failed(sliceIndex: slice.index, message: error.localizedDescription),
                nil,
                []
            )
        }
    }
}

enum TargetLoadingError: Error, Equatable, LocalizedError, Sendable {
    case targetChanged
    case imageNotFound(String)
    case imageChanged(String)
    case incompatibleImageFileType(String, String)
    case unsupportedSlice(Int)

    var errorDescription: String? {
        switch self {
        case .targetChanged:
            "The target changed after it was opened. Open it again before analyzing classes."
        case .imageNotFound(let imageID):
            "The selected image is no longer present in the target: \(imageID)"
        case .imageChanged(let name):
            "The selected image '\(name)' changed after the target was opened. Open it again before analyzing classes."
        case .incompatibleImageFileType(let name, let reason):
            "The image '\(name)' has an incompatible Mach-O file type. \(reason)"
        case .unsupportedSlice(let sliceIndex):
            "Slice \(sliceIndex) is unavailable or unsupported for patching."
        }
    }
}
