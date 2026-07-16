import MachPatchCore
import SwiftUI

struct PatchRuntimeControlEditorView: View {
    let patch: MethodPatch
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        GroupBox("In-App Control") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Show in target app",
                    isOn: Binding(
                        get: { patch.runtimeControl != nil },
                        set: { model.setRuntimeControlExposed($0, for: patch) }
                    )
                )

                if let control = patch.runtimeControl {
                    TextField(
                        "Display Name",
                        text: Binding(
                            get: { control.title },
                            set: { update(control.replacing(title: $0)) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Toggle(
                        "Patch Active by Default",
                        isOn: Binding(
                            get: { control.defaultEnabled },
                            set: { update(control.replacing(defaultEnabled: $0)) }
                        )
                    )

                    Label(
                        "The in-app switch chooses between running this patch and calling the original implementation unchanged.",
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Label(
                        "The last Patch or Original selection is restored automatically when the target launches.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if !patch.enabled {
                        Label(
                            "This control is preserved, but the disabled patch is omitted from builds.",
                            systemImage: "pause.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } else {
                    Text(
                        "Expose this patch through the generated floating controls. Nothing is added to the target app until at least one patch opts in."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }

    private func update(_ configuration: PatchRuntimeControlConfiguration) {
        model.updateRuntimeControl(for: patch, configuration: configuration)
    }
}

extension PatchRuntimeControlConfiguration {
    func replacing(
        title: String? = nil,
        defaultEnabled: Bool? = nil
    ) -> PatchRuntimeControlConfiguration {
        PatchRuntimeControlConfiguration(
            title: title ?? self.title,
            defaultEnabled: defaultEnabled ?? self.defaultEnabled,
            order: order
        )
    }
}
