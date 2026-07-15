import Foundation
import MachPatchBuilder
import MachPatchCore

struct LoadedTarget: Equatable, Sendable {
    let inputURL: URL
    let target: ResolvedTarget
    let inspection: MachOInspection
    let architectureReport: TargetArchitectureReport
    let iconData: Data?
    let analysisState: TargetAnalysisState

    func replacingAnalysisState(_ state: TargetAnalysisState) -> LoadedTarget {
        LoadedTarget(
            inputURL: inputURL,
            target: target,
            inspection: inspection,
            architectureReport: architectureReport,
            iconData: iconData,
            analysisState: state
        )
    }
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
