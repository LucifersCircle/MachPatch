import AppKit
import MachPatchCore
import SwiftUI

struct TargetSidebar: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        List(selection: $model.navigation) {
            Section {
                Button {
                    model.chooseTarget()
                } label: {
                    Label("Open Target…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
            }

            if case .loaded(let loadedTarget) = model.phase {
                Section("Target") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(for: loadedTarget))
                                .lineLimit(1)
                            Text(loadedTarget.target.sourceType.rawValue.uppercased())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        TargetIconView(iconData: loadedTarget.iconData, size: 24)
                    }
                    .tag(WorkspaceNavigation.target)
                }

                Section("Architectures") {
                    ForEach(loadedTarget.architectureReport.slices, id: \.index) { slice in
                        Button {
                            model.selectArchitecture(sliceIndex: slice.index)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(slice.architecture.rawValue)
                                    Text(slice.platform.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                architectureIcon(
                                    sliceIndex: slice.index, supported: slice.supportedForPatching)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!slice.supportedForPatching)
                    }
                }

                if let projectDraft = model.projectDraft {
                    Section("Patch Project") {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Build Workspace")
                                Text(
                                    "\(projectDraft.patches.count) patch\(projectDraft.patches.count == 1 ? "" : "es")"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "hammer.fill")
                                .foregroundStyle(
                                    model.navigation == .build
                                        ? Color(nsColor: .alternateSelectedControlTextColor)
                                        : .accentColor
                                )
                        }
                        .tag(WorkspaceNavigation.build)
                    }
                }

                analysisNavigation(loadedTarget)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MachPatch")
    }

    private func displayName(for loadedTarget: LoadedTarget) -> String {
        loadedTarget.target.displayName ?? loadedTarget.target.executableName
    }

    @ViewBuilder
    private func architectureIcon(sliceIndex: Int, supported: Bool) -> some View {
        if case .loaded(let loadedTarget) = model.phase,
            case .loading(let loadingIndex) = loadedTarget.analysisState,
            loadingIndex == sliceIndex
        {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(supported ? .green : .red)
        }
    }

    @ViewBuilder
    private func analysisNavigation(_ loadedTarget: LoadedTarget) -> some View {
        switch loadedTarget.analysisState {
        case .loaded(let analysis):
            let filteredClasses = model.filteredClasses.filter { !$0.isCategoryOnly }
            let filteredCategoryTargets = model.filteredClasses.filter(\.isCategoryOnly)
            let categoryTargetCount = loadedTarget.classBrowserTargets.count(
                where: \.isCategoryOnly)
            Section {
                TextField("Search classes or methods", text: $model.classSearch)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 4)
                Picker("Class Filter", selection: $model.classFilter) {
                    ForEach(ObjectiveCClassFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .padding(.horizontal, 4)
            }

            Section(
                "Classes · \(filteredClasses.count) of \(analysis.metadata.classes.count)"
            ) {
                ForEach(filteredClasses) { objectiveCClass in
                    classRow(objectiveCClass)
                }
            }

            if categoryTargetCount > 0 {
                Section(
                    "Category Targets · \(filteredCategoryTargets.count) of \(categoryTargetCount)"
                ) {
                    ForEach(filteredCategoryTargets) { objectiveCClass in
                        classRow(objectiveCClass)
                    }
                }
            }
        case .requiresSliceSelection:
            Section("Classes") {
                Label(
                    "Choose a supported architecture to analyze Objective-C metadata.",
                    systemImage: "cursorarrow.click"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .loading:
            Section("Classes") {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing Objective-C metadata…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let sliceIndex, let message):
            Section("Analysis Failed") {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry Slice \(sliceIndex)") {
                    model.selectArchitecture(sliceIndex: sliceIndex)
                }
            }
        case .unavailable(let reason):
            Section("Classes Unavailable") {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func classRow(_ objectiveCClass: ObjectiveCClassBrowserTarget) -> some View {
        let methodMatches = model.methodSearchMatches(for: objectiveCClass)
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(objectiveCClass.name)
                    .lineLimit(1)
                if let firstMatch = methodMatches.first {
                    Text(methodMatchSummary(firstMatch, total: methodMatches.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(methodMatchHelp(methodMatches))
                } else if let superclass = objectiveCClass.superclassName {
                    Text(superclass)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let categoryName = objectiveCClass.categoryNames.first {
                    Text(
                        objectiveCClass.categoryNames.count == 1
                            ? categoryName
                            : "\(categoryName) + \(objectiveCClass.categoryNames.count - 1) more"
                    )
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: classIcon(objectiveCClass))
                .foregroundStyle(classIconColor(objectiveCClass))
        }
        .tag(WorkspaceNavigation.objectiveCClass(objectiveCClass.id))
    }

    private func classIcon(_ objectiveCClass: ObjectiveCClassBrowserTarget) -> String {
        if objectiveCClass.isCategoryOnly {
            "square.stack.3d.up"
        } else if objectiveCClass.isObjectiveCVisibleSwift {
            "swift"
        } else if objectiveCClass.isLikelyAppDefined {
            "cube.fill"
        } else {
            "cube"
        }
    }

    private func classIconColor(_ objectiveCClass: ObjectiveCClassBrowserTarget) -> Color {
        if model.navigation == .objectiveCClass(objectiveCClass.id) {
            return Color(nsColor: .alternateSelectedControlTextColor)
        }
        if objectiveCClass.isObjectiveCVisibleSwift {
            return .orange
        }
        if objectiveCClass.isCategoryOnly {
            return .purple
        }
        return objectiveCClass.isLikelyAppDefined ? .accentColor : .secondary
    }

    private func methodMatchSummary(_ method: ObjectiveCCanonicalMethod, total: Int) -> String {
        let marker = method.kind == .instance ? "−" : "+"
        let remainder = total > 1 ? " + \(total - 1) more" : ""
        return "Method: \(marker)\(method.selector)\(remainder)"
    }

    private func methodMatchHelp(_ methods: [ObjectiveCCanonicalMethod]) -> String {
        "Matched methods:\n"
            + methods.map {
                let marker = $0.kind == .instance ? "−" : "+"
                return "\(marker)\($0.selector)"
            }.joined(separator: "\n")
    }
}
