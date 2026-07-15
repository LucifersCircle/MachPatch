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
                        Image(systemName: "app.dashed")
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
                "Classes · \(model.filteredClasses.count) of \(analysis.metadata.classes.count)"
            ) {
                ForEach(model.filteredClasses) { objectiveCClass in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(objectiveCClass.name)
                                .lineLimit(1)
                            if let superclass = objectiveCClass.superclassName {
                                Text(superclass)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } icon: {
                        Image(systemName: classIcon(objectiveCClass))
                            .foregroundStyle(
                                objectiveCClass.isLikelyAppDefined
                                    ? Color.accentColor : Color.secondary
                            )
                    }
                    .tag(WorkspaceNavigation.objectiveCClass(objectiveCClass.id))
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

    private func classIcon(_ objectiveCClass: ObjectiveCClass) -> String {
        if objectiveCClass.isObjectiveCVisibleSwift {
            "swift"
        } else if objectiveCClass.isLikelyAppDefined {
            "cube.fill"
        } else {
            "cube"
        }
    }
}
