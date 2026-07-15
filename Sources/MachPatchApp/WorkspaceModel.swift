import Combine
import Foundation
import MachPatchAnalyzer
import MachPatchBuilder
import MachPatchCore
import MachPatchGenerator
import MachPatchPackager
import MachPatchVerifier

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var phase: WorkspacePhase = .empty
    @Published var isImporterPresented = false
    @Published private(set) var isDropTargeted = false
    @Published var navigation: WorkspaceNavigation? = .target
    @Published var selectedMethodID: String?
    @Published var classSearch = ""
    @Published var classFilter: ObjectiveCClassFilter = .all
    @Published private(set) var projectDraft: PatchProjectDraft?
    @Published private(set) var savedPatchProjects: [SavedPatchProject] = []
    @Published var isProjectImporterPresented = false
    @Published var isProjectExporterPresented = false
    @Published var isDylibExporterPresented = false
    @Published private(set) var dylibExportDocument: DylibExportDocument?
    @Published var isSourceBundleExporterPresented = false
    @Published private(set) var sourceBundleExportDocument: SourceBundleExportDocument?
    @Published var isDebianPackageExporterPresented = false
    @Published private(set) var debianPackageExportDocument: DebianPackageExportDocument?
    @Published var workspaceAlert: WorkspaceAlert?
    @Published var pendingProjectImport: PendingProjectImport?
    @Published private(set) var generatedSourcePreview: GeneratedSourcePreviewState =
        .unavailable("Create a valid patch project to preview its generated source.")
    @Published private(set) var architecturePreview: ArchitecturePreviewState = .unavailable
    @Published private(set) var buildState: PatchBuildState = .idle
    @Published private(set) var verificationState: PatchVerificationState = .idle

    private let loader: any TargetLoading
    private let buildService: any PatchBuildServicing
    private let verificationService: any PatchVerificationServicing
    private let projectLibrary: any PatchProjectLibraryServicing
    private var loadTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var projectTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    private var buildID: UUID?

    init(
        loader: any TargetLoading = TargetLoader(),
        buildService: any PatchBuildServicing = PatchBuildService(),
        verificationService: any PatchVerificationServicing = PatchVerificationService(),
        projectLibrary: any PatchProjectLibraryServicing = PatchProjectLibrary()
    ) {
        self.loader = loader
        self.buildService = buildService
        self.verificationService = verificationService
        self.projectLibrary = projectLibrary
        refreshSavedPatchProjects(reportErrors: false)
    }

    func chooseTarget() {
        isImporterPresented = true
    }

    func importPatch() {
        isProjectImporterPresented = true
    }

    func setDropTargeted(_ isTargeted: Bool) {
        isDropTargeted = isTargeted
    }

    func openTarget(at inputURL: URL) {
        loadTask?.cancel()
        analysisTask?.cancel()
        projectTask?.cancel()
        resetBuildState(removingArtifact: true)
        navigation = .target
        selectedMethodID = nil
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

        resetBuildState(removingArtifact: true)
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

    var targetIconData: Data? {
        guard case .loaded(let loadedTarget) = phase else { return nil }
        return loadedTarget.iconData
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

    var canBuild: Bool {
        guard projectValidationReport?.isValid == true, !buildState.isBuilding,
            !verificationState.isVerifying
        else {
            return false
        }
        if case .resolved = architecturePreview { return true }
        return false
    }

    var defaultProjectFilename: String {
        let name = projectDraft?.outputName ?? "MachPatch"
        return "\(name).json"
    }

    var defaultDylibFilename: String {
        buildState.artifact?.dylibURL.lastPathComponent
            ?? "\(projectDraft?.outputName ?? "MachPatch").dylib"
    }

    var canExportDylib: Bool {
        guard case .succeeded = buildState,
            case .verified(let report) = verificationState
        else { return false }
        return report.isReadyForLiveContainerTesting
    }

    var canExportSourceBundle: Bool {
        guard case .succeeded = buildState, patchProject != nil else { return false }
        return true
    }

    var debianExportUnavailableReason: String? {
        guard case .succeeded(let artifact) = buildState else {
            return "Build the current patch project before creating a Debian package."
        }
        guard canExportDylib else {
            return "A successful LiveContainer verification is required before Debian export."
        }
        guard artifact.record.architecture == .arm64 else {
            return "Debian export currently supports ordinary arm64 output only."
        }
        guard patchProject?.target.bundleIdentifier?.isEmpty == false else {
            return "A bundle identifier is required for the MobileSubstrate filter plist."
        }
        return nil
    }

    var canExportDebianPackage: Bool {
        debianExportUnavailableReason == nil
    }

    var defaultSourceBundleFilename: String {
        "\(projectDraft?.outputName ?? "MachPatch")Source.zip"
    }

    var defaultDebianPackageFilename: String {
        "\(projectDraft?.outputName ?? "MachPatch").deb"
    }

    func exportPatch() {
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

    func savePatch() {
        guard let projectDraft else {
            workspaceAlert = WorkspaceAlert(
                title: "No Patch Project",
                message: "Choose and analyze a target before saving a patch."
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

        do {
            let savedProject = try projectLibrary.save(projectDraft.project)
            refreshSavedPatchProjects(reportErrors: false)
            workspaceAlert = WorkspaceAlert(
                title: "Patch Saved",
                message:
                    "Saved \(savedProject.projectName) to MachPatch’s private patch library."
            )
        } catch {
            workspaceAlert = WorkspaceAlert(
                title: "Couldn’t Save Patch",
                message: error.localizedDescription
            )
        }
    }

    func loadPatch(_ savedProject: SavedPatchProject) {
        openProject(at: savedProject.fileURL)
    }

    func refreshSavedPatchProjects() {
        refreshSavedPatchProjects(reportErrors: true)
    }

    func handleProjectExport(_ result: Result<URL, any Error>) {
        if case .failure(let error) = result {
            workspaceAlert = WorkspaceAlert(
                title: "Couldn’t Export Patch",
                message: error.localizedDescription
            )
        }
    }

    func exportDylib() {
        guard case .succeeded(let artifact) = buildState else {
            workspaceAlert = WorkspaceAlert(
                title: "Fresh Build Required",
                message: "Build the current patch project before exporting its dylib."
            )
            return
        }
        guard case .verified(let report) = verificationState,
            report.isReadyForLiveContainerTesting
        else {
            workspaceAlert = WorkspaceAlert(
                title: "Verification Required",
                message:
                    "Resolve every blocking verification failure before exporting the dylib."
            )
            return
        }

        do {
            dylibExportDocument = try DylibExportDocument(contentsOf: artifact.dylibURL)
            isDylibExporterPresented = true
        } catch {
            workspaceAlert = WorkspaceAlert(
                title: "Couldn’t Prepare Dylib",
                message: error.localizedDescription
            )
        }
    }

    func handleDylibExport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            workspaceAlert = WorkspaceAlert(
                title: "Dylib Exported",
                message:
                    "Saved \(url.lastPathComponent) to \(url.deletingLastPathComponent().path)."
            )
        case .failure(let error):
            workspaceAlert = WorkspaceAlert(
                title: "Couldn’t Export Dylib",
                message: error.localizedDescription
            )
        }
        dylibExportDocument = nil
    }

    func exportSourceBundle() {
        guard case .succeeded(let artifact) = buildState,
            let project = patchProject
        else {
            workspaceAlert = WorkspaceAlert(
                title: "Fresh Build Required",
                message: "Build the current patch project before exporting its source bundle."
            )
            return
        }

        do {
            let archive = try PatchSourceArchiveBuilder().build(
                project: project,
                buildRecord: artifact.record,
                sourceURL: artifact.sourceURL
            )
            sourceBundleExportDocument = SourceBundleExportDocument(archive: archive)
            isSourceBundleExporterPresented = true
        } catch {
            workspaceAlert = WorkspaceAlert(
                title: "Couldn’t Prepare Source Bundle",
                message: error.localizedDescription
            )
        }
    }

    func handleSourceBundleExport(_ result: Result<URL, any Error>) {
        handleOptionalExport(
            result,
            successTitle: "Source Bundle Exported",
            failureTitle: "Couldn’t Export Source Bundle"
        )
        sourceBundleExportDocument = nil
    }

    func exportDebianPackage() {
        guard debianExportUnavailableReason == nil,
            case .succeeded(let artifact) = buildState,
            let project = patchProject
        else {
            workspaceAlert = WorkspaceAlert(
                title: "Debian Export Unavailable",
                message: debianExportUnavailableReason
                    ?? "Build and verify the current project before creating a Debian package."
            )
            return
        }

        do {
            let package = try DebianPackageBuilder().build(
                project: project,
                buildRecord: artifact.record,
                dylibURL: artifact.dylibURL
            )
            debianPackageExportDocument = DebianPackageExportDocument(package: package)
            isDebianPackageExporterPresented = true
        } catch {
            workspaceAlert = WorkspaceAlert(
                title: "Couldn’t Prepare Debian Package",
                message: error.localizedDescription
            )
        }
    }

    func handleDebianPackageExport(_ result: Result<URL, any Error>) {
        handleOptionalExport(
            result,
            successTitle: "Debian Package Exported",
            failureTitle: "Couldn’t Export Debian Package"
        )
        debianPackageExportDocument = nil
    }

    private func handleOptionalExport(
        _ result: Result<URL, any Error>,
        successTitle: String,
        failureTitle: String
    ) {
        switch result {
        case .success(let url):
            workspaceAlert = WorkspaceAlert(
                title: successTitle,
                message:
                    "Saved \(url.lastPathComponent) to \(url.deletingLastPathComponent().path)."
            )
        case .failure(let error):
            workspaceAlert = WorkspaceAlert(
                title: failureTitle,
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

    func inspectPatch(_ patch: MethodPatch) {
        guard
            let objectiveCClass = analysis?.metadata.classes.first(where: {
                $0.name == patch.className
            })
        else {
            workspaceAlert = WorkspaceAlert(
                title: "Patch Target Unavailable",
                message: "The analyzed target does not contain the class \(patch.className)."
            )
            return
        }

        let methods = objectiveCClass.instanceMethods + objectiveCClass.classMethods
        guard
            let method = methods.first(where: {
                $0.selector == patch.selector && $0.kind == patch.methodKind
            })
        else {
            let marker = patch.methodKind == .instance ? "−" : "+"
            workspaceAlert = WorkspaceAlert(
                title: "Patch Target Unavailable",
                message:
                    "The analyzed target does not contain \(marker)[\(patch.className) \(patch.selector)]."
            )
            return
        }

        selectedMethodID = method.id
        navigation = .objectiveCClass(objectiveCClass.id)
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

    func buildDylib() {
        guard canBuild, let project = patchProject,
            case .loaded(let loadedTarget) = phase
        else {
            workspaceAlert = WorkspaceAlert(
                title: "Project Isn’t Buildable",
                message: "Fix the project and architecture validation errors before building."
            )
            return
        }

        let buildID = UUID()
        let previousArtifact = buildState.artifact
        self.buildID = buildID
        verificationState = .idle
        buildState = .building(
            PatchBuildProgress(
                phase: .preparing,
                completedUnitCount: 0,
                totalUnitCount: 1,
                message: "Preparing an isolated build workspace…"
            ),
            previousArtifact: previousArtifact
        )
        let buildService = buildService
        let verificationService = verificationService
        let targetInspection = loadedTarget.inspection
        let handleProgress: @MainActor @Sendable (PatchBuildProgress) -> Void = {
            [weak self] progress in
            guard self?.buildID == buildID else { return }
            self?.buildState = .building(
                progress,
                previousArtifact: previousArtifact
            )
        }

        buildTask = Task { [weak self] in
            do {
                let artifact = try await Task.detached(priority: .userInitiated) {
                    try buildService.build(project: project) { progress in
                        Task { @MainActor in
                            handleProgress(progress)
                        }
                    }
                }.value
                guard let self, self.buildID == buildID else {
                    Self.removeBuildArtifact(artifact)
                    return
                }
                if let previousArtifact,
                    previousArtifact.workspaceURL != artifact.workspaceURL
                {
                    Self.removeBuildArtifact(previousArtifact)
                }
                self.buildState = .succeeded(artifact)
                self.verificationState = .verifying

                do {
                    let report = try await Task.detached(priority: .userInitiated) {
                        try verificationService.verify(
                            artifact: artifact,
                            targetInspection: targetInspection
                        )
                    }.value
                    guard self.buildID == buildID else { return }
                    self.buildID = nil
                    self.verificationState = .verified(report)
                } catch {
                    guard self.buildID == buildID else { return }
                    self.buildID = nil
                    self.verificationState = .failed(PatchVerificationFailure(error: error))
                }
            } catch {
                guard let self, self.buildID == buildID else { return }
                self.buildID = nil
                self.buildState = .failed(
                    PatchBuildFailure(error: error),
                    previousArtifact: previousArtifact
                )
            }
        }
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
    }

    private func refreshSavedPatchProjects(reportErrors: Bool) {
        do {
            savedPatchProjects = try projectLibrary.savedProjects()
        } catch {
            savedPatchProjects = []
            if reportErrors {
                workspaceAlert = WorkspaceAlert(
                    title: "Couldn’t Read Saved Patches",
                    message: error.localizedDescription
                )
            }
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
        invalidateBuildState()
        self.projectDraft = projectDraft
        refreshBuildWorkspace()
    }

    private func invalidateBuildState() {
        switch buildState {
        case .building(_, let previousArtifact):
            buildTask?.cancel()
            buildID = nil
            buildState = previousArtifact.map(PatchBuildState.stale) ?? .idle
        case .succeeded(let artifact):
            buildState = .stale(artifact)
        case .failed(_, let previousArtifact):
            buildState = previousArtifact.map(PatchBuildState.stale) ?? .idle
        case .idle, .stale:
            break
        }
        if buildState.artifact == nil {
            verificationState = .idle
        } else {
            verificationState = .unavailable(
                "The project changed after this dylib was built. Rebuild to verify it again."
            )
        }
        isDylibExporterPresented = false
        dylibExportDocument = nil
        isSourceBundleExporterPresented = false
        sourceBundleExportDocument = nil
        isDebianPackageExporterPresented = false
        debianPackageExportDocument = nil
    }

    private func resetBuildState(removingArtifact: Bool) {
        buildTask?.cancel()
        buildID = nil
        if removingArtifact, let artifact = buildState.artifact {
            Self.removeBuildArtifact(artifact)
        }
        buildState = .idle
        verificationState = .idle
        isDylibExporterPresented = false
        dylibExportDocument = nil
        isSourceBundleExporterPresented = false
        sourceBundleExportDocument = nil
        isDebianPackageExporterPresented = false
        debianPackageExportDocument = nil
    }

    private nonisolated static func removeBuildArtifact(_ artifact: PatchBuildArtifact) {
        try? FileManager.default.removeItem(at: artifact.workspaceURL)
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
