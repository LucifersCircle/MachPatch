import Foundation
import MachPatchBuilder
import MachPatchCore

struct LoadedTarget: Equatable, Sendable {
    let inputURL: URL
    let target: ResolvedTarget
    let inspection: MachOInspection
    let architectureReport: TargetArchitectureReport
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
