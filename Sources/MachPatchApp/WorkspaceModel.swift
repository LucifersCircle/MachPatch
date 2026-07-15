import Combine
import Foundation
import MachPatchCore

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var phase: WorkspacePhase = .empty
    @Published var isImporterPresented = false
    @Published private(set) var isDropTargeted = false
    @Published var navigation: WorkspaceNavigation? = .target
    @Published var classSearch = ""
    @Published var classFilter: ObjectiveCClassFilter = .likelyAppDefined

    private let loader: any TargetLoading
    private var loadTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    init(loader: any TargetLoading = TargetLoader()) {
        self.loader = loader
    }

    func chooseTarget() {
        isImporterPresented = true
    }

    func setDropTargeted(_ isTargeted: Bool) {
        isDropTargeted = isTargeted
    }

    func openTarget(at inputURL: URL) {
        loadTask?.cancel()
        analysisTask?.cancel()
        navigation = .target
        classSearch = ""
        phase = .loading(inputURL)
        let loader = loader

        loadTask = Task { [weak self] in
            do {
                let loadedTarget = try await loader.loadTarget(at: inputURL)
                try Task.checkCancellation()
                self?.phase = .loaded(loadedTarget)
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
                self?.phase = .loaded(
                    currentTarget.replacingAnalysisState(.loaded(analysis))
                )
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

    private func matchesQuery(_ objectiveCClass: ObjectiveCClass, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if objectiveCClass.name.localizedCaseInsensitiveContains(query)
            || objectiveCClass.superclassName?.localizedCaseInsensitiveContains(query) == true
            || objectiveCClass.imageName?.localizedCaseInsensitiveContains(query) == true
        {
            return true
        }
        return (objectiveCClass.instanceMethods + objectiveCClass.classMethods).contains {
            $0.selector.localizedCaseInsensitiveContains(query)
        }
    }
}
