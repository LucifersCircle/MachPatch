import Foundation
import MachPatchBuilder
import MachPatchCore

struct LoadedTargetImage: Equatable, Identifiable, Sendable {
    let image: ResolvedImage
    let inspectionState: TargetImageInspectionState

    var id: String { image.id }
}

enum TargetImageInspectionState: Equatable, Sendable {
    case available(slices: [MachOSlice], architectureReport: TargetArchitectureReport)
    case failed(String)

    var slices: [MachOSlice] {
        guard case .available(let slices, _) = self else { return [] }
        return slices
    }

    var architectureReport: TargetArchitectureReport? {
        guard case .available(_, let report) = self else { return nil }
        return report
    }
}

struct LoadedTarget: Equatable, Sendable {
    let inputURL: URL
    let target: ResolvedTarget
    let inspection: MachOInspection
    let architectureReport: TargetArchitectureReport
    let images: [LoadedTargetImage]
    let iconData: Data?
    let analysisState: TargetAnalysisState
    let patchabilityReport: ObjectiveCPatchabilityReport?
    let classBrowserTargets: [ObjectiveCClassBrowserTarget]

    var selectedImage: LoadedTargetImage? {
        images.first { $0.id == inspection.image.id }
    }

    init(
        inputURL: URL,
        target: ResolvedTarget,
        inspection: MachOInspection,
        architectureReport: TargetArchitectureReport,
        images: [LoadedTargetImage]? = nil,
        iconData: Data?,
        analysisState: TargetAnalysisState,
        patchabilityReport: ObjectiveCPatchabilityReport?,
        classBrowserTargets: [ObjectiveCClassBrowserTarget]
    ) {
        self.inputURL = inputURL
        self.target = target
        self.inspection = inspection
        self.architectureReport = architectureReport
        self.images =
            images ?? [
                LoadedTargetImage(
                    image: target.primaryImage,
                    inspectionState: .available(
                        slices: inspection.slices,
                        architectureReport: architectureReport
                    )
                )
            ]
        self.iconData = iconData
        self.analysisState = analysisState
        self.patchabilityReport = patchabilityReport
        self.classBrowserTargets = classBrowserTargets
    }

    func replacingAnalysisState(
        _ state: TargetAnalysisState,
        patchabilityReport: ObjectiveCPatchabilityReport? = nil,
        classBrowserTargets: [ObjectiveCClassBrowserTarget]? = nil
    ) -> LoadedTarget {
        let resolvedPatchabilityReport: ObjectiveCPatchabilityReport?
        if let patchabilityReport {
            resolvedPatchabilityReport = patchabilityReport
        } else if case .loaded(let analysis) = state {
            resolvedPatchabilityReport = ObjectiveCPatchabilityAnalyzer.report(
                for: analysis.metadata
            )
        } else {
            resolvedPatchabilityReport = nil
        }
        let resolvedClassBrowserTargets: [ObjectiveCClassBrowserTarget]
        if let classBrowserTargets {
            resolvedClassBrowserTargets = classBrowserTargets
        } else if case .loaded(let analysis) = state {
            resolvedClassBrowserTargets = ObjectiveCClassBrowserCatalog.targets(for: analysis)
        } else {
            resolvedClassBrowserTargets = []
        }
        return LoadedTarget(
            inputURL: inputURL,
            target: target,
            inspection: inspection,
            architectureReport: architectureReport,
            images: images,
            iconData: iconData,
            analysisState: state,
            patchabilityReport: resolvedPatchabilityReport,
            classBrowserTargets: resolvedClassBrowserTargets
        )
    }

    func selectingImage(
        id imageID: String,
        analysisState: TargetAnalysisState
    ) -> LoadedTarget? {
        guard let selectedImage = images.first(where: { $0.id == imageID }),
            case .available(let slices, let report) = selectedImage.inspectionState
        else { return nil }

        return LoadedTarget(
            inputURL: inputURL,
            target: target,
            inspection: MachOInspection(
                target: target,
                image: selectedImage.image,
                slices: slices
            ),
            architectureReport: report,
            images: images,
            iconData: iconData,
            analysisState: analysisState,
            patchabilityReport: nil,
            classBrowserTargets: []
        )
    }
}

struct LoadedObjectiveCAnalysis: Equatable, Sendable {
    let analysis: ObjectiveCAnalysis
    let patchabilityReport: ObjectiveCPatchabilityReport
    let classBrowserTargets: [ObjectiveCClassBrowserTarget]
}

enum TargetAnalysisState: Equatable, Sendable {
    case unavailable(String)
    case requiresSliceSelection
    case loading(sliceIndex: Int)
    case loaded(ObjectiveCAnalysis)
    case failed(sliceIndex: Int, message: String)

    var sliceIndex: Int? {
        switch self {
        case .loading(let sliceIndex), .failed(let sliceIndex, _):
            sliceIndex
        case .loaded(let analysis):
            analysis.sliceIndex
        case .unavailable, .requiresSliceSelection:
            nil
        }
    }
}

enum WorkspacePhase: Equatable, Sendable {
    case empty
    case loading(URL)
    case loaded(LoadedTarget)
    case failed(WorkspaceFailure)
}

struct WorkspaceFailure: Equatable, Sendable {
    let inputURL: URL
    let message: String
}

struct WorkspaceAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    static func == (lhs: WorkspaceAlert, rhs: WorkspaceAlert) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message
    }
}

struct PendingProjectImport: Identifiable, Equatable {
    let id = UUID()
    let project: PatchProject
    let currentTargetIdentity: PatchTargetIdentity
    let warnings: [PatchProjectValidationIssue]

    static func == (lhs: PendingProjectImport, rhs: PendingProjectImport) -> Bool {
        lhs.project == rhs.project && lhs.currentTargetIdentity == rhs.currentTargetIdentity
            && lhs.warnings == rhs.warnings
    }
}

enum WorkspaceNavigation: Hashable {
    case target
    case objectiveCClass(String)
    case build
}

enum ObjectiveCClassFilter: String, CaseIterable, Identifiable {
    case all = "All Classes"
    case likelyAppDefined = "Likely App-Defined"
    case objectiveCVisibleSwift = "Objective-C Swift"
    case withProperties = "With Properties"

    var id: Self { self }
}
