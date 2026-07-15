import Combine
import Foundation
import MachPatchAnalyzer
import MachPatchBuilder
import MachPatchCore
import MachPatchGenerator

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var phase: WorkspacePhase = .empty
    @Published var isImporterPresented = false
    @Published private(set) var isDropTargeted = false
    @Published var navigation: WorkspaceNavigation? = .target
    @Published var classSearch = ""
    @Published var classFilter: ObjectiveCClassFilter = .all
    @Published private(set) var projectDraft: PatchProjectDraft?
    @Published var isProjectImporterPresented = false
    @Published var isProjectExporterPresented = false
    @Published var workspaceAlert: WorkspaceAlert?
    @Published var pendingProjectImport: PendingProjectImport?
    @Published private(set) var generatedSourcePreview: GeneratedSourcePreviewState =
        .unavailable("Create a valid patch project to preview its generated source.")
    @Published private(set) var architecturePreview: ArchitecturePreviewState = .unavailable

    private let loader: any TargetLoading
    private var loadTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var projectTask: Task<Void, Never>?

    init(loader: any TargetLoading = TargetLoader()) {
        self.loader = loader
    }

    func chooseTarget() {
        isImporterPresented = true
    }

    func chooseProject() {
        isProjectImporterPresented = true
    }

    func setDropTargeted(_ isTargeted: Bool) {
        isDropTargeted = isTargeted
    }

    func openTarget(at inputURL: URL) {
        loadTask?.cancel()
        analysisTask?.cancel()
        projectTask?.cancel()
        navigation = .target
        classSearch = ""
        classFilter = .all
        replaceProjectDraft(nil)
        phase = .loading(inputURL)
        let loader = loader

        loadTask = Task { [weak self] in
            do {
                let loadedTarget = try await loader.loadTarget(at: inputURL)
                try Task.checkCancellation()
                self?.phase = .loaded(loadedTarget)
                self?.replaceProjectDraft(PatchProjectDraft(loadedTarget: loadedTarget))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(
                    WorkspaceFailure(
                        inputURL: inputURL,
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    func selectArchitecture(sliceIndex: Int) {
        guard case .loaded(let loadedTarget) = phase else { return }
        guard
            loadedTarget.architectureReport.slices.contains(where: {
                $0.index == sliceIndex && $0.supportedForPatching
            })
        else { return }

        if case .loaded(let analysis) = loadedTarget.analysisState,
            analysis.sliceIndex == sliceIndex
        {
            navigation = .target
            return
        }

        analysisTask?.cancel()
        navigation = .target
        phase = .loaded(loadedTarget.replacingAnalysisState(.loading(sliceIndex: sliceIndex)))
        let loader = loader

        analysisTask = Task { [weak self] in
            do {
                let analysis = try await loader.loadAnalysis(
                    at: loadedTarget.inputURL,
                    expectedSHA256: loadedTarget.target.sha256,
                    sliceIndex: sliceIndex
                )
                try Task.checkCancellation()
                guard case .loaded(let currentTarget) = self?.phase,
                    currentTarget.target.sha256 == loadedTarget.target.sha256
                else { return }
                let analyzedTarget = currentTarget.replacingAnalysisState(.loaded(analysis))
                self?.phase = .loaded(analyzedTarget)
                self?.replaceProjectDraft(PatchProjectDraft(loadedTarget: analyzedTarget))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard case .loaded(let currentTarget) = self?.phase,
                    currentTarget.target.sha256 == loadedTarget.target.sha256
                else { return }
                self?.phase = .loaded(
                    currentTarget.replacingAnalysisState(
                        .failed(sliceIndex: sliceIndex, message: error.localizedDescription)
                    )
                )
            }
        }
    }

    var analysis: ObjectiveCAnalysis? {
        guard case .loaded(let loadedTarget) = phase,
            case .loaded(let analysis) = loadedTarget.analysisState
        else { return nil }
        return analysis
    }

    var filteredClasses: [ObjectiveCClass] {
        guard let analysis else { return [] }
        let query = classSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return analysis.metadata.classes.filter { objectiveCClass in
            matchesFilter(objectiveCClass) && matchesQuery(objectiveCClass, query: query)
        }
    }

    var selectedClass: ObjectiveCClass? {
        guard case .objectiveCClass(let classID) = navigation else { return nil }
        return analysis?.metadata.classes.first { $0.id == classID }
    }

    func methodSearchMatches(for objectiveCClass: ObjectiveCClass) -> [ObjectiveCMethod] {
        let query = classSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !matchesClassMetadata(objectiveCClass, query: query) else {
            return []
        }
        return (objectiveCClass.instanceMethods + objectiveCClass.classMethods).filter {
            $0.selector.localizedCaseInsensitiveContains(query)
        }
    }

    var patchProject: PatchProject? {
        projectDraft?.project
    }

    var projectValidationReport: PatchProjectValidationReport? {
        projectDraft?.validationReport
    }

    var availableArchitectureModes: [PatchArchitectureMode] {
        guard let architecture = projectDraft?.target.selectedSlice.architecture else { return [] }
        switch architecture {
        case .arm64:
            return [.automatic, .arm64, .universal]
        case .arm64e:
            return [.automatic, .arm64e, .universal]
        default:
            return [.automatic]
        }
    }

    var projectDocument: PatchProjectDocument? {
        patchProject.map(PatchProjectDocument.init(project:))
    }

    var defaultProjectFilename: String {
        let name = projectDraft?.outputName ?? "MachPatch"
        return "\(name).json"
    }

    func saveProject() {
        guard let projectDraft else {
            workspaceAlert = WorkspaceAlert(
                title: "No Patch Project",
                message: "Choose and analyze a target before saving a patch project."
            )
            return
        }
        let report = projectDraft.validationReport
        guard report.isValid else {
            workspaceAlert = WorkspaceAlert(
                title: "Project Has Validation Errors",
                message: report.errors.map(\.message).joined(separator: "\n")
            )
            return
        }
        isProjectExporterPresented = true
    }

    func handleProjectExport(_ result: Result<URL, any Error>) {
        if case .failure(let error) = result {
            workspaceAlert = WorkspaceAlert(
                title: "Couldn’t Save Project",
                message: error.localizedDescription
            )
        }
    }

    func openProject(at projectURL: URL) {
        guard case .loaded(let loadedTarget) = phase,
            case .loaded(let analysis) = loadedTarget.analysisState,
            let selectedSlice = loadedTarget.inspection.slices.first(where: {
                $0.index == analysis.sliceIndex
            }),
            let currentTargetIdentity = PatchProjectDraft.targetIdentity(for: loadedTarget)
        else {
            workspaceAlert = WorkspaceAlert(
                title: "Analyze a Target First",
                message:
                    "Open a target and choose a supported architecture before opening its patch project."
            )
            return
        }

        projectTask?.cancel()
        projectTask = Task { [weak self] in
            do {
                let project = try await Self.readProject(at: projectURL)
                try Task.checkCancellation()
                let report = AnalyzedPatchProjectValidator.validate(
                    project,
                    against: analysis,
                    selectedSlice: selectedSlice
                )
                guard report.errors.isEmpty else {
                    self?.workspaceAlert = WorkspaceAlert(
                        title: "Project Is Incompatible",
                        message: report.errors.map(\.message).joined(separator: "\n")
                    )
                    return
                }
                if report.warnings.isEmpty {
                    self?.loadProject(project)
                } else {
                    self?.pendingProjectImport = PendingProjectImport(
                        project: project,
                        currentTargetIdentity: currentTargetIdentity,
                        warnings: report.warnings
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                self?.workspaceAlert = WorkspaceAlert(
                    title: "Couldn’t Open Project",
                    message: error.localizedDescription
                )
            }
        }
    }

    func resolvePendingProjectImport(retarget: Bool) {
        guard let pendingProjectImport else { return }
        let targetOverride = retarget ? pendingProjectImport.currentTargetIdentity : nil
        loadProject(pendingProjectImport.project, targetOverride: targetOverride)
        self.pendingProjectImport = nil
    }

    func cancelPendingProjectImport() {
        pendingProjectImport = nil
    }

    func patch(className: String, method: ObjectiveCMethod) -> MethodPatch? {
        projectDraft?.patch(className: className, method: method)
    }

    @discardableResult
    func addPatch(className: String, method: ObjectiveCMethod) throws -> MethodPatch {
        guard var projectDraft else { throw PatchDraftError.projectUnavailable }
        let patch = try projectDraft.addPatch(className: className, method: method)
        replaceProjectDraft(projectDraft)
        return patch
    }

    func updatePatch(_ patch: MethodPatch) {
        guard var projectDraft else { return }
        projectDraft.updatePatch(patch)
        replaceProjectDraft(projectDraft)
    }

    func removePatch(id: String) {
        guard var projectDraft else { return }
        projectDraft.removePatch(id: id)
        replaceProjectDraft(projectDraft)
    }

    func updateProjectName(_ projectName: String) {
        updateProjectDraft { $0.projectName = projectName }
    }

    func updateArchitectureMode(_ architectureMode: PatchArchitectureMode) {
        guard availableArchitectureModes.contains(architectureMode) else { return }
        updateProjectDraft { $0.architectureMode = architectureMode }
    }

    func updateMinimumIOSVersion(_ minimumIOSVersion: String) {
        updateProjectDraft { $0.minimumIOSVersion = minimumIOSVersion }
    }

    func updateOutputName(_ outputName: String) {
        updateProjectDraft { $0.outputName = outputName }
    }

    func updateARCEnabled(_ enableARC: Bool) {
        updateProjectDraft { $0.enableARC = enableARC }
    }

    private func matchesFilter(_ objectiveCClass: ObjectiveCClass) -> Bool {
        switch classFilter {
        case .all:
            true
        case .likelyAppDefined:
            objectiveCClass.isLikelyAppDefined
        case .objectiveCVisibleSwift:
            objectiveCClass.isObjectiveCVisibleSwift
        case .withProperties:
            !objectiveCClass.properties.isEmpty
        }
    }

    private func loadProject(
        _ project: PatchProject,
        targetOverride: PatchTargetIdentity? = nil
    ) {
        replaceProjectDraft(PatchProjectDraft(project: project, targetOverride: targetOverride))
        if let firstPatch = project.patches.first,
            let objectiveCClass = analysis?.metadata.classes.first(where: {
                $0.name == firstPatch.className
            })
        {
            navigation = .objectiveCClass(objectiveCClass.id)
        }
    }

    private nonisolated static func readProject(at projectURL: URL) async throws -> PatchProject {
        try await Task.detached(priority: .userInitiated) {
            let hasSecurityScope = projectURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    projectURL.stopAccessingSecurityScopedResource()
                }
            }
            return try PatchProjectCodec.decode(Data(contentsOf: projectURL))
        }.value
    }

    private func matchesQuery(_ objectiveCClass: ObjectiveCClass, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if matchesClassMetadata(objectiveCClass, query: query) {
            return true
        }
        return !methodSearchMatches(for: objectiveCClass).isEmpty
    }

    private func matchesClassMetadata(
        _ objectiveCClass: ObjectiveCClass,
        query: String
    ) -> Bool {
        objectiveCClass.name.localizedCaseInsensitiveContains(query)
            || objectiveCClass.superclassName?.localizedCaseInsensitiveContains(query) == true
            || objectiveCClass.imageName?.localizedCaseInsensitiveContains(query) == true
    }

    private func updateProjectDraft(_ update: (inout PatchProjectDraft) -> Void) {
        guard var projectDraft else { return }
        update(&projectDraft)
        replaceProjectDraft(projectDraft)
    }

    private func replaceProjectDraft(_ projectDraft: PatchProjectDraft?) {
        self.projectDraft = projectDraft
        refreshBuildWorkspace()
    }

    private func refreshBuildWorkspace() {
        guard let projectDraft else {
            architecturePreview = .unavailable
            generatedSourcePreview = .unavailable(
                "Create a valid patch project to preview its generated source."
            )
            return
        }

        do {
            architecturePreview = .resolved(
                try ArchitectureResolver.resolve(
                    mode: projectDraft.architectureMode,
                    selectedSlice: projectDraft.target.selectedSlice
                )
            )
        } catch {
            architecturePreview = .failed(error.localizedDescription)
        }

        guard projectDraft.validationReport.isValid else {
            generatedSourcePreview = .unavailable(
                "Fix the project validation errors to regenerate the source preview."
            )
            return
        }

        do {
            generatedSourcePreview = .ready(
                try ObjectiveCSourceGenerator().generate(projectDraft.project)
            )
        } catch {
            generatedSourcePreview = .unavailable(error.localizedDescription)
        }
    }
}

enum GeneratedSourcePreviewState: Equatable {
    case unavailable(String)
    case ready(GeneratedSourceBundle)
}

enum ArchitecturePreviewState: Equatable {
    case unavailable
    case resolved(BuildArchitectureResolution)
    case failed(String)
}
