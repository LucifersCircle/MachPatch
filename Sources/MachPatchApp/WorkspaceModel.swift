import Combine
import Foundation
import MachPatchAnalyzer
import MachPatchBuilder
import MachPatchCore
import MachPatchGenerator
import MachPatchPackager
import MachPatchVerifier

struct MethodRevealRequest: Equatable, Identifiable {
    let id = UUID()
    let methodID: String
}

enum PendingWorkspaceTransition: Equatable {
    case startNewPatch
    case openTarget(URL)
    case openProject(URL)
    case selectArchitecture(Int)
    case selectImage(String)

    var confirmationMessage: String {
        switch self {
        case .startNewPatch:
            "Starting a new patch will reset the current project and remove its method patches."
        case .openTarget(let url):
            "Opening \(url.lastPathComponent) will replace the current target and patch project."
        case .openProject(let url):
            "Loading \(url.deletingPathExtension().lastPathComponent) will replace the current patch project."
        case .selectArchitecture:
            "Selecting another architecture will replace the current patch project."
        case .selectImage:
            "Selecting another target image will replace the current patch project."
        }
    }

    var continueActionTitle: String {
        switch self {
        case .startNewPatch:
            "Start New Patch"
        case .openTarget:
            "Open Target"
        case .openProject:
            "Load Patch"
        case .selectArchitecture:
            "Switch Architecture"
        case .selectImage:
            "Switch Image"
        }
    }
}

private struct TargetAnalysisCacheKey: Hashable {
    let hostSHA256: String
    let imageID: String
    let imageSHA256: String
    let sliceIndex: Int
}

enum WorkspaceExportKind: String, Equatable, Hashable {
    case patchProject = "Patch Project"
    case dylib = "Dylib"
    case sourceBundle = "Source Bundle"
    case debianPackage = "Debian Package"
}

struct CompletedWorkspaceExport: Equatable, Identifiable {
    let kind: WorkspaceExportKind
    let url: URL

    var id: String { "\(kind.rawValue):\(url.path)" }
    var shareLabel: String { "Share \(url.lastPathComponent)…" }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var phase: WorkspacePhase = .empty {
        didSet { refreshClassBrowserIndex() }
    }
    @Published var isImporterPresented = false
    @Published private(set) var isDropTargeted = false
    @Published var navigation: WorkspaceNavigation? = .target
    @Published var selectedMethodID: String?
    @Published private(set) var methodRevealRequest: MethodRevealRequest?
    @Published var classSearch = "" {
        didSet { refreshClassBrowserResults() }
    }
    @Published var classFilter: ObjectiveCClassFilter = .all {
        didSet { refreshClassBrowserResults() }
    }
    @Published private(set) var filteredClasses: [ObjectiveCClassBrowserTarget] = []
    @Published private(set) var projectDraft: PatchProjectDraft?
    @Published private(set) var savedPatchProjects: [SavedPatchProject] = []
    @Published var pendingSavedPatchDeletion: SavedPatchProject?
    @Published var pendingPatchDeletion: MethodPatch?
    @Published private(set) var pendingWorkspaceTransition: PendingWorkspaceTransition?
    @Published var isProjectImporterPresented = false
    @Published var isProjectExporterPresented = false
    @Published var isDylibExporterPresented = false
    @Published private(set) var dylibExportDocument: DylibExportDocument?
    @Published var isSourceBundleExporterPresented = false
    @Published private(set) var sourceBundleExportDocument: SourceBundleExportDocument?
    @Published var isDebianPackageExporterPresented = false
    @Published private(set) var debianPackageExportDocument: DebianPackageExportDocument?
    @Published private(set) var lastCompletedExport: CompletedWorkspaceExport?
    @Published private(set) var shareableArtifacts:
        [WorkspaceExportKind: CompletedWorkspaceExport] =
            [:]
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
    private var savedProjectBaseline: PatchProject?
    private var analysisCache: [TargetAnalysisCacheKey: LoadedObjectiveCAnalysis] = [:]
    private var analysisCacheRecency: [TargetAnalysisCacheKey] = []
    private var classBrowserTargetsByID: [String: ObjectiveCClassBrowserTarget] = [:]
    private var classBrowserTargetsByName: [String: ObjectiveCClassBrowserTarget] = [:]
    private var classBrowserTargetsByFilter:
        [ObjectiveCClassFilter: [ObjectiveCClassBrowserTarget]] = [:]
    private var classBrowserTargetIDsByFilter: [ObjectiveCClassFilter: Set<String>] = [:]
    private var methodSearchMatchesByClassID: [String: [ObjectiveCCanonicalMethod]] = [:]
    private var isClassBrowserRefreshSuspended = false

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
        requestWorkspaceTransition(.openTarget(inputURL))
    }

    private func beginOpeningTarget(at inputURL: URL) {
        loadTask?.cancel()
        analysisTask?.cancel()
        projectTask?.cancel()
        analysisCache = [:]
        analysisCacheRecency = []
        resetBuildState(removingArtifact: true)
        navigation = .target
        selectedMethodID = nil
        methodRevealRequest = nil
        resetClassBrowserQuery()
        savedProjectBaseline = nil
        replaceProjectDraft(nil)
        phase = .loading(inputURL)
        let loader = loader

        loadTask = Task { [weak self] in
            do {
                let loadedTarget = try await loader.loadTarget(at: inputURL)
                try Task.checkCancellation()
                self?.cacheLoadedAnalysis(in: loadedTarget)
                self?.phase = .loaded(loadedTarget)
                self?.replaceProjectDraft(
                    PatchProjectDraft(loadedTarget: loadedTarget),
                    marksClean: true
                )
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

        requestWorkspaceTransition(.selectArchitecture(sliceIndex))
    }

    private func beginSelectingArchitecture(sliceIndex: Int) {
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

        let cacheKey = analysisCacheKey(for: loadedTarget, sliceIndex: sliceIndex)
        if let cachedAnalysis = cachedAnalysis(for: cacheKey) {
            resetBuildState(removingArtifact: true)
            navigation = .target
            let analyzedTarget = loadedTarget.replacingAnalysisState(
                .loaded(cachedAnalysis.analysis),
                patchabilityReport: cachedAnalysis.patchabilityReport,
                classBrowserTargets: cachedAnalysis.classBrowserTargets
            )
            phase = .loaded(analyzedTarget)
            replaceProjectDraft(
                PatchProjectDraft(loadedTarget: analyzedTarget),
                marksClean: true
            )
            return
        }

        resetBuildState(removingArtifact: true)
        analysisTask?.cancel()
        navigation = .target
        phase = .loaded(
            loadedTarget.replacingAnalysisState(
                .loading(sliceIndex: sliceIndex),
                patchabilityReport: nil,
                classBrowserTargets: []
            )
        )
        let loader = loader

        analysisTask = Task { [weak self] in
            do {
                let loadedAnalysis = try await loader.loadAnalysis(
                    at: loadedTarget.inputURL,
                    expectedHostSHA256: loadedTarget.target.sha256,
                    imageID: loadedTarget.inspection.image.id,
                    expectedImageSHA256: loadedTarget.inspection.image.sha256,
                    sliceIndex: sliceIndex
                )
                try Task.checkCancellation()
                guard case .loaded(let currentTarget) = self?.phase,
                    currentTarget.target.sha256 == loadedTarget.target.sha256,
                    currentTarget.inspection.image.id == loadedTarget.inspection.image.id
                else { return }
                let analysis = loadedAnalysis.analysis
                self?.storeCachedAnalysis(loadedAnalysis, for: cacheKey)
                let analyzedTarget = currentTarget.replacingAnalysisState(
                    .loaded(analysis),
                    patchabilityReport: loadedAnalysis.patchabilityReport,
                    classBrowserTargets: loadedAnalysis.classBrowserTargets
                )
                self?.phase = .loaded(analyzedTarget)
                self?.replaceProjectDraft(
                    PatchProjectDraft(loadedTarget: analyzedTarget),
                    marksClean: true
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard case .loaded(let currentTarget) = self?.phase,
                    currentTarget.target.sha256 == loadedTarget.target.sha256,
                    currentTarget.inspection.image.id == loadedTarget.inspection.image.id
                else { return }
                self?.phase = .loaded(
                    currentTarget.replacingAnalysisState(
                        .failed(sliceIndex: sliceIndex, message: error.localizedDescription),
                        patchabilityReport: nil,
                        classBrowserTargets: []
                    )
                )
            }
        }
    }

    func selectImage(id imageID: String) {
        guard case .loaded(let loadedTarget) = phase else { return }
        guard loadedTarget.inspection.image.id != imageID else {
            navigation = .target
            return
        }
        guard let image = loadedTarget.images.first(where: { $0.id == imageID }) else {
            workspaceAlert = WorkspaceAlert(
                title: "Image Unavailable",
                message: "The selected image is no longer part of this target."
            )
            return
        }
        guard case .available = image.inspectionState else {
            if case .failed(let message) = image.inspectionState {
                workspaceAlert = WorkspaceAlert(
                    title: "Image Inspection Failed",
                    message: message
                )
            }
            return
        }

        requestWorkspaceTransition(.selectImage(imageID))
    }

    private func beginSelectingImage(id imageID: String) {
        guard case .loaded(let loadedTarget) = phase else { return }
        guard loadedTarget.inspection.image.id != imageID else {
            navigation = .target
            return
        }
        guard let image = loadedTarget.images.first(where: { $0.id == imageID }) else {
            workspaceAlert = WorkspaceAlert(
                title: "Image Unavailable",
                message: "The selected image is no longer part of this target."
            )
            return
        }
        guard case .available(_, let architectureReport) = image.inspectionState else {
            if case .failed(let message) = image.inspectionState {
                workspaceAlert = WorkspaceAlert(
                    title: "Image Inspection Failed",
                    message: message
                )
            }
            return
        }

        resetBuildState(removingArtifact: true)
        analysisTask?.cancel()
        navigation = .target
        selectedMethodID = nil
        methodRevealRequest = nil
        resetClassBrowserQuery()
        savedProjectBaseline = nil
        replaceProjectDraft(nil)

        let supportedSlices = architectureReport.slices.filter(\.supportedForPatching)
        let initialState: TargetAnalysisState
        if supportedSlices.isEmpty {
            initialState = .unavailable(architectureReport.automaticReason)
        } else if supportedSlices.count == 1, let slice = supportedSlices.first {
            initialState = .loading(sliceIndex: slice.index)
        } else {
            initialState = .requiresSliceSelection
        }
        guard
            let selectedTarget = loadedTarget.selectingImage(
                id: imageID,
                analysisState: initialState
            )
        else { return }
        phase = .loaded(selectedTarget)

        if supportedSlices.count == 1, let slice = supportedSlices.first {
            beginSelectingArchitecture(sliceIndex: slice.index)
        }
    }

    var analysis: ObjectiveCAnalysis? {
        guard case .loaded(let loadedTarget) = phase,
            case .loaded(let analysis) = loadedTarget.analysisState
        else { return nil }
        return analysis
    }

    var selectedClass: ObjectiveCClassBrowserTarget? {
        guard case .objectiveCClass(let classID) = navigation else { return nil }
        return classBrowserTargetsByID[classID]
    }

    var targetIconData: Data? {
        guard case .loaded(let loadedTarget) = phase else { return nil }
        return loadedTarget.iconData
    }

    func methodSearchMatches(
        for objectiveCClass: ObjectiveCClassBrowserTarget
    ) -> [ObjectiveCCanonicalMethod] {
        methodSearchMatchesByClassID[objectiveCClass.id] ?? []
    }

    var patchProject: PatchProject? {
        projectDraft?.project
    }

    var hasUnsavedPatchChanges: Bool {
        guard let patchProject else { return false }
        return patchProject != savedProjectBaseline
    }

    var pendingWorkspaceTransitionHasUnsavedChanges: Bool {
        pendingWorkspaceTransition != nil && hasUnsavedPatchChanges
    }

    var canStartNewPatch: Bool {
        guard case .loaded(let loadedTarget) = phase else { return false }
        return PatchProjectDraft(loadedTarget: loadedTarget) != nil
    }

    var projectValidationReport: PatchProjectValidationReport? {
        projectDraft?.validationReport
    }

    var currentTargetIdentity: PatchTargetIdentity? {
        guard case .loaded(let loadedTarget) = phase else { return nil }
        return PatchProjectDraft.targetIdentity(for: loadedTarget)
    }

    var loadableSavedPatchProjects: [SavedPatchProject] {
        guard let currentTargetIdentity else { return [] }
        return savedPatchProjects.filter { $0.isRelevant(to: currentTargetIdentity) }
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

    func shareableArtifact(for kind: WorkspaceExportKind) -> CompletedWorkspaceExport? {
        shareableArtifacts[kind]
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

    @discardableResult
    func savePatch(showSuccessAlert: Bool = true) -> Bool {
        guard let projectDraft else {
            workspaceAlert = WorkspaceAlert(
                title: "No Patch Project",
                message: "Choose and analyze a target before saving a patch."
            )
            return false
        }
        let report = projectDraft.validationReport
        guard report.isValid else {
            workspaceAlert = WorkspaceAlert(
                title: "Project Has Validation Errors",
                message: report.errors.map(\.message).joined(separator: "\n")
            )
            return false
        }

        do {
            let savedProject = try projectLibrary.save(projectDraft.project)
            savedProjectBaseline = projectDraft.project
            refreshSavedPatchProjects(reportErrors: false)
            if showSuccessAlert {
                workspaceAlert = WorkspaceAlert(
                    title: "Patch Saved",
                    message:
                        "Saved \(savedProject.projectName) to MachPatch’s private patch library."
                )
            }
            return true
        } catch {
            workspaceAlert = WorkspaceAlert(
                title: "Couldn’t Save Patch",
                message: error.localizedDescription
            )
            return false
        }
    }

    func requestNewPatch() {
        guard canStartNewPatch else {
            workspaceAlert = WorkspaceAlert(
                title: "Analyze a Target First",
                message:
                    "Open a target and choose a supported architecture before starting a patch."
            )
            return
        }
        requestWorkspaceTransition(.startNewPatch)
    }

    func saveAndPerformPendingWorkspaceTransition() {
        guard let transition = pendingWorkspaceTransition else { return }
        pendingWorkspaceTransition = nil
        guard savePatch(showSuccessAlert: false) else {
            pendingWorkspaceTransition = transition
            return
        }
        performWorkspaceTransition(transition)
    }

    func discardAndPerformPendingWorkspaceTransition() {
        guard let transition = pendingWorkspaceTransition else { return }
        pendingWorkspaceTransition = nil
        performWorkspaceTransition(transition)
    }

    func cancelPendingWorkspaceTransition() {
        pendingWorkspaceTransition = nil
    }

    func loadPatch(_ savedProject: SavedPatchProject) {
        openProject(at: savedProject.fileURL)
    }

    func requestDeleteSavedPatch(_ savedProject: SavedPatchProject) {
        guard savedPatchProjects.contains(savedProject) else { return }
        pendingSavedPatchDeletion = savedProject
    }

    func confirmDeleteSavedPatch() {
        guard let savedProject = pendingSavedPatchDeletion else { return }
        pendingSavedPatchDeletion = nil
        do {
            try projectLibrary.delete(savedProject)
            refreshSavedPatchProjects(reportErrors: false)
            workspaceAlert = WorkspaceAlert(
                title: "Saved Patch Deleted",
                message: "Deleted \(savedProject.projectName) from MachPatch’s private library."
            )
        } catch {
            refreshSavedPatchProjects(reportErrors: false)
            workspaceAlert = WorkspaceAlert(
                title: "Couldn’t Delete Saved Patch",
                message: error.localizedDescription
            )
        }
    }

    func cancelDeleteSavedPatch() {
        pendingSavedPatchDeletion = nil
    }

    func refreshSavedPatchProjects() {
        refreshSavedPatchProjects(reportErrors: true)
    }

    func handleProjectExport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            savedProjectBaseline = patchProject
            completeExport(kind: .patchProject, url: url)
        case .failure(let error):
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
            completeExport(kind: .dylib, url: url)
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
            kind: .sourceBundle,
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
            kind: .debianPackage,
            failureTitle: "Couldn’t Export Debian Package"
        )
        debianPackageExportDocument = nil
    }

    private func handleOptionalExport(
        _ result: Result<URL, any Error>,
        kind: WorkspaceExportKind,
        failureTitle: String
    ) {
        switch result {
        case .success(let url):
            completeExport(kind: kind, url: url)
        case .failure(let error):
            workspaceAlert = WorkspaceAlert(
                title: failureTitle,
                message: error.localizedDescription
            )
        }
    }

    private func completeExport(kind: WorkspaceExportKind, url: URL) {
        let completedExport = CompletedWorkspaceExport(kind: kind, url: url)
        lastCompletedExport = completedExport
        shareableArtifacts[kind] = completedExport
    }

    func openProject(at projectURL: URL) {
        requestWorkspaceTransition(.openProject(projectURL))
    }

    private func beginOpeningProject(at projectURL: URL) {
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

    func patch(className: String, method: ObjectiveCCanonicalMethod) -> MethodPatch? {
        projectDraft?.patch(className: className, method: method.method)
    }

    func inspectPatch(_ patch: MethodPatch) {
        guard
            case .loaded = phase,
            let objectiveCClass = classBrowserTargetsByName[patch.className]
        else {
            workspaceAlert = WorkspaceAlert(
                title: "Patch Target Unavailable",
                message: "The analyzed target does not contain the class \(patch.className)."
            )
            return
        }

        guard
            let method = objectiveCClass.method(
                kind: patch.methodKind,
                selector: patch.selector
            )
        else {
            let marker = patch.methodKind == .instance ? "−" : "+"
            workspaceAlert = WorkspaceAlert(
                title: "Patch Target Unavailable",
                message:
                    "The analyzed target does not contain \(marker)[\(patch.className) \(patch.selector)]."
            )
            return
        }

        revealMethod(method)
        navigation = .objectiveCClass(objectiveCClass.id)
    }

    func revealMethod(_ method: ObjectiveCCanonicalMethod) {
        selectedMethodID = method.id
        methodRevealRequest = MethodRevealRequest(methodID: method.id)
    }

    func consumeMethodRevealRequest(id: UUID) {
        guard methodRevealRequest?.id == id else { return }
        methodRevealRequest = nil
    }

    @discardableResult
    func addPatch(className: String, method: ObjectiveCCanonicalMethod) throws -> MethodPatch {
        guard var projectDraft else { throw PatchDraftError.projectUnavailable }
        guard !method.hasConflictingTypeEncodings else {
            throw PatchDraftError.conflictingTypeEncodings(method.conflictingTypeEncodings)
        }
        let patch = try projectDraft.addPatch(className: className, method: method.method)
        replaceProjectDraft(projectDraft)
        return patch
    }

    @discardableResult
    func addPatch(className: String, method: ObjectiveCMethod) throws -> MethodPatch {
        guard let analysis,
            let canonicalMethod = ObjectiveCMethodCatalog.method(
                forClassNamed: className,
                kind: method.kind,
                selector: method.selector,
                in: analysis.metadata
            )
        else { throw PatchDraftError.projectUnavailable }
        return try addPatch(className: className, method: canonicalMethod)
    }

    func updatePatch(_ patch: MethodPatch) {
        guard var projectDraft else { return }
        projectDraft.updatePatch(patch)
        replaceProjectDraft(projectDraft)
    }

    func setRuntimeControlExposed(_ exposed: Bool, for patch: MethodPatch) {
        guard var projectDraft,
            projectDraft.patches.contains(where: { $0.id == patch.id })
        else { return }

        if exposed {
            guard patch.runtimeControl == nil else { return }
            if projectDraft.runtimeControls == nil {
                projectDraft.runtimeControls = PatchRuntimeControlsConfiguration(
                    id: UUID().uuidString
                )
            }
            let nextOrder =
                (projectDraft.patches.compactMap { $0.runtimeControl?.order }.max() ?? -1) + 1
            projectDraft.updatePatch(
                patch.replacingRuntimeControl(
                    PatchRuntimeControlConfiguration(
                        title: patch.selector,
                        order: nextOrder
                    )
                )
            )
        } else {
            guard patch.runtimeControl != nil else { return }
            projectDraft.updatePatch(patch.replacingRuntimeControl(nil))
        }
        replaceProjectDraft(projectDraft)
    }

    func updateRuntimeControl(
        for patch: MethodPatch,
        configuration: PatchRuntimeControlConfiguration
    ) {
        guard var projectDraft, projectDraft.runtimeControls != nil,
            projectDraft.patches.contains(where: { $0.id == patch.id })
        else { return }
        projectDraft.updatePatch(patch.replacingRuntimeControl(configuration))
        replaceProjectDraft(projectDraft)
    }

    func updateRuntimeControlActivationMode(_ activationMode: PatchRuntimeControlActivationMode) {
        updateProjectDraft { draft in
            let configuration =
                draft.runtimeControls
                ?? PatchRuntimeControlsConfiguration(id: UUID().uuidString)
            draft.runtimeControls = PatchRuntimeControlsConfiguration(
                id: configuration.id,
                activationMode: activationMode
            )
        }
    }

    func removePatch(id: String) {
        guard var projectDraft else { return }
        projectDraft.removePatch(id: id)
        replaceProjectDraft(projectDraft)
    }

    func requestDeletePatch(_ patch: MethodPatch) {
        guard projectDraft?.patches.contains(where: { $0.id == patch.id }) == true else { return }
        pendingPatchDeletion = patch
    }

    func confirmDeletePatch() {
        guard let patch = pendingPatchDeletion else { return }
        pendingPatchDeletion = nil
        removePatch(id: patch.id)
    }

    func cancelDeletePatch() {
        pendingPatchDeletion = nil
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

        clearShareableBuildArtifacts()
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
                    let verification = try await Task.detached(priority: .userInitiated) {
                        let report = try verificationService.verify(
                            artifact: artifact,
                            targetInspection: targetInspection
                        )
                        let record = try PatchBuildProvenanceRecorder.record(
                            verification: report,
                            in: artifact.record
                        )
                        return (report, record)
                    }.value
                    guard self.buildID == buildID else { return }
                    let verifiedArtifact = PatchBuildArtifact(
                        workspaceURL: artifact.workspaceURL,
                        record: verification.1
                    )
                    self.buildID = nil
                    self.buildState = .succeeded(verifiedArtifact)
                    self.verificationState = .verified(verification.0)
                    self.prepareShareableBuildArtifacts(
                        project: project,
                        artifact: verifiedArtifact,
                        verifiedForDeployment: verification.0.isReadyForLiveContainerTesting
                    )
                } catch {
                    guard self.buildID == buildID else { return }
                    self.buildID = nil
                    var shareArtifact = artifact
                    if let failedRecord =
                        try? PatchBuildProvenanceRecorder
                        .recordVerificationFailure(
                            error.localizedDescription,
                            in: artifact.record
                        )
                    {
                        shareArtifact = PatchBuildArtifact(
                            workspaceURL: artifact.workspaceURL,
                            record: failedRecord
                        )
                        self.buildState = .succeeded(shareArtifact)
                    }
                    self.verificationState = .failed(PatchVerificationFailure(error: error))
                    self.prepareShareableBuildArtifacts(
                        project: project,
                        artifact: shareArtifact,
                        verifiedForDeployment: false
                    )
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

    private func clearShareableBuildArtifacts() {
        shareableArtifacts[.dylib] = nil
        shareableArtifacts[.sourceBundle] = nil
        shareableArtifacts[.debianPackage] = nil
    }

    private func prepareShareableBuildArtifacts(
        project: PatchProject,
        artifact: PatchBuildArtifact,
        verifiedForDeployment: Bool
    ) {
        let shareDirectory = artifact.workspaceURL.appending(
            path: "Share",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: shareDirectory,
                withIntermediateDirectories: true
            )
            let archive = try PatchSourceArchiveBuilder().build(
                project: project,
                buildRecord: artifact.record,
                sourceURL: artifact.sourceURL
            )
            let archiveURL = shareDirectory.appending(path: archive.filename)
            try archive.contents.write(to: archiveURL, options: .atomic)
            shareableArtifacts[.sourceBundle] = CompletedWorkspaceExport(
                kind: .sourceBundle,
                url: archiveURL
            )
        } catch {
            shareableArtifacts[.sourceBundle] = nil
        }

        guard verifiedForDeployment else {
            shareableArtifacts[.dylib] = nil
            shareableArtifacts[.debianPackage] = nil
            return
        }

        shareableArtifacts[.dylib] = CompletedWorkspaceExport(
            kind: .dylib,
            url: artifact.dylibURL
        )

        do {
            let package = try DebianPackageBuilder().build(
                project: project,
                buildRecord: artifact.record,
                dylibURL: artifact.dylibURL
            )
            let packageURL = shareDirectory.appending(path: package.filename)
            try package.contents.write(to: packageURL, options: .atomic)
            shareableArtifacts[.debianPackage] = CompletedWorkspaceExport(
                kind: .debianPackage,
                url: packageURL
            )
        } catch {
            shareableArtifacts[.debianPackage] = nil
        }
    }

    private func matchesFilter(
        _ objectiveCClass: ObjectiveCClassBrowserTarget,
        filter: ObjectiveCClassFilter
    ) -> Bool {
        switch filter {
        case .all:
            true
        case .likelyAppDefined:
            objectiveCClass.isLikelyAppDefined
        case .likelyThirdPartySDK:
            objectiveCClass.isLikelyThirdPartySDK
        case .uikitSubclass:
            objectiveCClass.isUIKitSubclass
        case .objectiveCVisibleSwift:
            objectiveCClass.isObjectiveCVisibleSwift
        case .withProperties:
            !objectiveCClass.properties.isEmpty
        case .declaredBySelectedImage:
            objectiveCClass.isDeclaredBySelectedImage
        }
    }

    private func refreshClassBrowserIndex() {
        guard case .loaded(let loadedTarget) = phase else {
            classBrowserTargetsByID = [:]
            classBrowserTargetsByName = [:]
            classBrowserTargetsByFilter = [:]
            classBrowserTargetIDsByFilter = [:]
            filteredClasses = []
            methodSearchMatchesByClassID = [:]
            return
        }

        classBrowserTargetsByID = loadedTarget.classBrowserTargets.reduce(into: [:]) {
            $0[$1.id] = $1
        }
        classBrowserTargetsByName = loadedTarget.classBrowserTargets.reduce(into: [:]) {
            $0[$1.name] = $1
        }
        classBrowserTargetsByFilter = Dictionary(
            uniqueKeysWithValues: ObjectiveCClassFilter.allCases.map { filter in
                let targets =
                    filter == .all
                    ? loadedTarget.classBrowserTargets
                    : loadedTarget.classBrowserTargets.filter {
                        matchesFilter($0, filter: filter)
                    }
                return (filter, targets)
            }
        )
        classBrowserTargetIDsByFilter = classBrowserTargetsByFilter.mapValues { targets in
            Set(targets.map(\.id))
        }
        refreshClassBrowserResults()
    }

    private func refreshClassBrowserResults() {
        guard !isClassBrowserRefreshSuspended else { return }
        guard case .loaded(let loadedTarget) = phase else {
            filteredClasses = []
            methodSearchMatchesByClassID = [:]
            return
        }

        let query = classSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates =
            classBrowserTargetsByFilter[classFilter] ?? loadedTarget.classBrowserTargets
        guard !query.isEmpty else {
            filteredClasses = candidates
            methodSearchMatchesByClassID = [:]
            reconcileClassSelection(
                visibleClassIDs: classBrowserTargetIDsByFilter[classFilter]
                    ?? Set(candidates.map(\.id))
            )
            return
        }

        var results: [ObjectiveCClassBrowserTarget] = []
        results.reserveCapacity(candidates.count)
        var methodMatches: [String: [ObjectiveCCanonicalMethod]] = [:]

        for target in candidates {
            if matchesClassMetadata(target, query: query) {
                results.append(target)
                continue
            }

            let matchingMethods = target.methods.filter { method in
                method.selector.localizedCaseInsensitiveContains(query)
                    || method.categoryNames.contains(where: {
                        $0.localizedCaseInsensitiveContains(query)
                    })
            }
            if !matchingMethods.isEmpty {
                results.append(target)
                methodMatches[target.id] = matchingMethods
                continue
            }

            if target.categoryNames.contains(where: {
                $0.localizedCaseInsensitiveContains(query)
            }) {
                results.append(target)
            }
        }

        filteredClasses = results
        methodSearchMatchesByClassID = methodMatches
        reconcileClassSelection(visibleClassIDs: Set(results.map(\.id)))
    }

    private func reconcileClassSelection(visibleClassIDs: Set<String>) {
        guard case .objectiveCClass(let classID) = navigation,
            !visibleClassIDs.contains(classID)
        else { return }
        navigation = nil
        selectedMethodID = nil
        methodRevealRequest = nil
    }

    private func resetClassBrowserQuery() {
        isClassBrowserRefreshSuspended = true
        classSearch = ""
        classFilter = .all
        isClassBrowserRefreshSuspended = false
    }

    private func analysisCacheKey(
        for loadedTarget: LoadedTarget,
        sliceIndex: Int
    ) -> TargetAnalysisCacheKey {
        TargetAnalysisCacheKey(
            hostSHA256: loadedTarget.target.sha256,
            imageID: loadedTarget.inspection.image.id,
            imageSHA256: loadedTarget.inspection.image.sha256,
            sliceIndex: sliceIndex
        )
    }

    private func cacheLoadedAnalysis(in loadedTarget: LoadedTarget) {
        guard case .loaded(let analysis) = loadedTarget.analysisState else { return }
        let report =
            loadedTarget.patchabilityReport
            ?? ObjectiveCPatchabilityAnalyzer.report(for: analysis.metadata)
        let targets =
            loadedTarget.classBrowserTargets.isEmpty
            ? ObjectiveCClassBrowserCatalog.targets(for: analysis)
            : loadedTarget.classBrowserTargets
        storeCachedAnalysis(
            LoadedObjectiveCAnalysis(
                analysis: analysis,
                patchabilityReport: report,
                classBrowserTargets: targets
            ),
            for: analysisCacheKey(for: loadedTarget, sliceIndex: analysis.sliceIndex)
        )
    }

    private func cachedAnalysis(
        for key: TargetAnalysisCacheKey
    ) -> LoadedObjectiveCAnalysis? {
        guard let analysis = analysisCache[key] else { return nil }
        analysisCacheRecency.removeAll { $0 == key }
        analysisCacheRecency.append(key)
        return analysis
    }

    private func storeCachedAnalysis(
        _ analysis: LoadedObjectiveCAnalysis,
        for key: TargetAnalysisCacheKey
    ) {
        analysisCache[key] = analysis
        analysisCacheRecency.removeAll { $0 == key }
        analysisCacheRecency.append(key)
        while analysisCacheRecency.count > 8 {
            let evictedKey = analysisCacheRecency.removeFirst()
            analysisCache[evictedKey] = nil
        }
    }

    private func loadProject(
        _ project: PatchProject,
        targetOverride: PatchTargetIdentity? = nil
    ) {
        replaceProjectDraft(
            PatchProjectDraft(project: project, targetOverride: targetOverride),
            marksClean: true
        )
    }

    private func startNewPatch() {
        guard case .loaded(let loadedTarget) = phase,
            let draft = PatchProjectDraft(loadedTarget: loadedTarget)
        else { return }

        pendingPatchDeletion = nil
        pendingProjectImport = nil
        resetBuildState(removingArtifact: true)
        replaceProjectDraft(draft, marksClean: true)
    }

    private func requestWorkspaceTransition(_ transition: PendingWorkspaceTransition) {
        guard pendingWorkspaceTransition == nil else { return }
        if hasUnsavedPatchChanges || projectDraft?.patches.isEmpty == false {
            pendingWorkspaceTransition = transition
        } else {
            performWorkspaceTransition(transition)
        }
    }

    private func performWorkspaceTransition(_ transition: PendingWorkspaceTransition) {
        switch transition {
        case .startNewPatch:
            startNewPatch()
        case .openTarget(let url):
            beginOpeningTarget(at: url)
        case .openProject(let url):
            beginOpeningProject(at: url)
        case .selectArchitecture(let sliceIndex):
            beginSelectingArchitecture(sliceIndex: sliceIndex)
        case .selectImage(let imageID):
            beginSelectingImage(id: imageID)
        }
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

    private func matchesClassMetadata(
        _ objectiveCClass: ObjectiveCClassBrowserTarget,
        query: String
    ) -> Bool {
        objectiveCClass.name.localizedCaseInsensitiveContains(query)
            || objectiveCClass.superclassName?.localizedCaseInsensitiveContains(query) == true
            || objectiveCClass.imageName.localizedCaseInsensitiveContains(query)
    }

    private func updateProjectDraft(_ update: (inout PatchProjectDraft) -> Void) {
        guard var projectDraft else { return }
        update(&projectDraft)
        replaceProjectDraft(projectDraft)
    }

    private func replaceProjectDraft(
        _ projectDraft: PatchProjectDraft?,
        marksClean: Bool = false
    ) {
        let projectChanged = self.projectDraft?.project != projectDraft?.project
        self.projectDraft = projectDraft
        if marksClean {
            savedProjectBaseline = projectDraft?.project
        }
        guard projectChanged else { return }
        invalidateBuildState()
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
        shareableArtifacts = [:]
        lastCompletedExport = nil
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
