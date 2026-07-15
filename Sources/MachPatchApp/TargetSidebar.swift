import SwiftUI

struct TargetSidebar: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        List {
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
                }

                Section("Architectures") {
                    ForEach(loadedTarget.architectureReport.slices, id: \.index) { slice in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slice.architecture.rawValue)
                                Text(slice.platform.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(
                                systemName: slice.supportedForPatching
                                    ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(slice.supportedForPatching ? .green : .red)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MachPatch")
    }

    private func displayName(for loadedTarget: LoadedTarget) -> String {
        loadedTarget.target.displayName ?? loadedTarget.target.executableName
    }
}
