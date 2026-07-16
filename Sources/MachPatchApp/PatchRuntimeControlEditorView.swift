import MachPatchCore
import SwiftUI

struct PatchRuntimeControlEditorView: View {
    let patch: MethodPatch
    let signature: ObjectiveCMethodSignature
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

                    Picker(
                        "Control Type",
                        selection: Binding(
                            get: { editorKind(for: control).rawValue },
                            set: { rawValue in
                                guard let kind = RuntimeControlEditorKind(rawValue: rawValue) else {
                                    return
                                }
                                update(control.replacingValue(value(for: kind)))
                            }
                        )
                    ) {
                        ForEach(availableEditorKinds, id: \.rawValue) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }

                    Toggle(
                        "Active by Default",
                        isOn: Binding(
                            get: { control.defaultEnabled },
                            set: { update(control.replacing(defaultEnabled: $0)) }
                        )
                    )

                    Picker(
                        "Persistence",
                        selection: Binding(
                            get: { control.persistence },
                            set: { update(control.replacing(persistence: $0)) }
                        )
                    ) {
                        ForEach(PatchRuntimeControlPersistence.allCases, id: \.self) {
                            persistence in
                            Text(persistence.displayName).tag(persistence)
                        }
                    }

                    typedValueEditor(control)

                    Label(
                        "When inactive, the hook calls the original method without running any patch behavior.",
                        systemImage: "arrow.uturn.backward.circle"
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

    @ViewBuilder
    private func typedValueEditor(_ control: PatchRuntimeControlConfiguration) -> some View {
        switch control.value {
        case .boolean(let value):
            Picker(
                "Patched Value",
                selection: Binding(
                    get: { value },
                    set: { update(control.replacingValue(.boolean($0))) }
                )
            ) {
                Text("False").tag(false)
                Text("True").tag(true)
            }
            .pickerStyle(.segmented)
        case .signedInteger(let integer):
            signedIntegerEditor(integer, control: control)
        case .unsignedInteger(let integer):
            unsignedIntegerEditor(integer, control: control)
        case nil:
            EmptyView()
        }
    }

    private func signedIntegerEditor(
        _ integer: PatchRuntimeSignedIntegerConfiguration,
        control: PatchRuntimeControlConfiguration
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField(
                "Default Value",
                value: signedBinding(integer, control: control, keyPath: \.defaultValue),
                format: .number.grouping(.never)
            )
            TextField(
                "Step",
                value: signedBinding(integer, control: control, keyPath: \.step),
                format: .number.grouping(.never)
            )
            Toggle(
                "Custom Range",
                isOn: Binding(
                    get: { integer.minimumValue != nil || integer.maximumValue != nil },
                    set: { enabled in
                        let bounds = signedBounds
                        update(
                            control.replacingValue(
                                .signedInteger(
                                    PatchRuntimeSignedIntegerConfiguration(
                                        defaultValue: integer.defaultValue,
                                        minimumValue: enabled ? bounds.lowerBound : nil,
                                        maximumValue: enabled ? bounds.upperBound : nil,
                                        step: integer.step
                                    )
                                )
                            )
                        )
                    }
                )
            )
            if integer.minimumValue != nil || integer.maximumValue != nil {
                HStack {
                    TextField(
                        "Minimum",
                        value: signedOptionalBinding(
                            integer,
                            control: control,
                            isMinimum: true
                        ),
                        format: .number.grouping(.never)
                    )
                    TextField(
                        "Maximum",
                        value: signedOptionalBinding(
                            integer,
                            control: control,
                            isMinimum: false
                        ),
                        format: .number.grouping(.never)
                    )
                }
            }
            Text("Allowed ABI range: \(signedBounds.lowerBound)…\(signedBounds.upperBound)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func unsignedIntegerEditor(
        _ integer: PatchRuntimeUnsignedIntegerConfiguration,
        control: PatchRuntimeControlConfiguration
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField(
                "Default Value",
                value: unsignedBinding(integer, control: control, keyPath: \.defaultValue),
                format: .number.grouping(.never)
            )
            TextField(
                "Step",
                value: unsignedBinding(integer, control: control, keyPath: \.step),
                format: .number.grouping(.never)
            )
            Toggle(
                "Custom Range",
                isOn: Binding(
                    get: { integer.minimumValue != nil || integer.maximumValue != nil },
                    set: { enabled in
                        update(
                            control.replacingValue(
                                .unsignedInteger(
                                    PatchRuntimeUnsignedIntegerConfiguration(
                                        defaultValue: integer.defaultValue,
                                        minimumValue: enabled ? 0 : nil,
                                        maximumValue: enabled ? unsignedMaximum : nil,
                                        step: integer.step
                                    )
                                )
                            )
                        )
                    }
                )
            )
            if integer.minimumValue != nil || integer.maximumValue != nil {
                HStack {
                    TextField(
                        "Minimum",
                        value: unsignedOptionalBinding(
                            integer,
                            control: control,
                            isMinimum: true
                        ),
                        format: .number.grouping(.never)
                    )
                    TextField(
                        "Maximum",
                        value: unsignedOptionalBinding(
                            integer,
                            control: control,
                            isMinimum: false
                        ),
                        format: .number.grouping(.never)
                    )
                }
            }
            Text("Allowed ABI range: 0…\(unsignedMaximum)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var availableEditorKinds: [RuntimeControlEditorKind] {
        var result: [RuntimeControlEditorKind] = [.toggle]
        switch PatchRuntimeControlCompatibility.defaultEditableValue(for: patch.action) {
        case .boolean:
            result.append(.boolean)
        case .signedInteger:
            result.append(.signedInteger)
        case .unsignedInteger:
            result.append(.unsignedInteger)
        case nil:
            break
        }
        return result
    }

    private func editorKind(
        for control: PatchRuntimeControlConfiguration
    ) -> RuntimeControlEditorKind {
        switch control.value {
        case .boolean: .boolean
        case .signedInteger: .signedInteger
        case .unsignedInteger: .unsignedInteger
        case nil: .toggle
        }
    }

    private func value(for kind: RuntimeControlEditorKind) -> PatchRuntimeControlValue? {
        switch kind {
        case .toggle:
            nil
        case .boolean, .signedInteger, .unsignedInteger:
            PatchRuntimeControlCompatibility.defaultEditableValue(for: patch.action)
        }
    }

    private var signedBounds: ClosedRange<Int64> {
        switch signature.returnType.kind {
        case .signedChar: Int64(Int8.min)...Int64(Int8.max)
        case .signedShort: Int64(Int16.min)...Int64(Int16.max)
        case .signedInt: Int64(Int32.min)...Int64(Int32.max)
        default: Int64.min...Int64.max
        }
    }

    private var unsignedMaximum: UInt64 {
        switch signature.returnType.kind {
        case .unsignedChar: UInt64(UInt8.max)
        case .unsignedShort: UInt64(UInt16.max)
        case .unsignedInt: UInt64(UInt32.max)
        default: UInt64.max
        }
    }

    private func signedBinding(
        _ integer: PatchRuntimeSignedIntegerConfiguration,
        control: PatchRuntimeControlConfiguration,
        keyPath: KeyPath<PatchRuntimeSignedIntegerConfiguration, Int64>
    ) -> Binding<Int64> {
        Binding(
            get: { integer[keyPath: keyPath] },
            set: { value in
                let replacement = PatchRuntimeSignedIntegerConfiguration(
                    defaultValue: keyPath == \.defaultValue ? value : integer.defaultValue,
                    minimumValue: integer.minimumValue,
                    maximumValue: integer.maximumValue,
                    step: keyPath == \.step ? value : integer.step
                )
                update(control.replacingValue(.signedInteger(replacement)))
            }
        )
    }

    private func signedOptionalBinding(
        _ integer: PatchRuntimeSignedIntegerConfiguration,
        control: PatchRuntimeControlConfiguration,
        isMinimum: Bool
    ) -> Binding<Int64> {
        Binding(
            get: { (isMinimum ? integer.minimumValue : integer.maximumValue) ?? 0 },
            set: { value in
                update(
                    control.replacingValue(
                        .signedInteger(
                            PatchRuntimeSignedIntegerConfiguration(
                                defaultValue: integer.defaultValue,
                                minimumValue: isMinimum ? value : integer.minimumValue,
                                maximumValue: isMinimum ? integer.maximumValue : value,
                                step: integer.step
                            )
                        )
                    )
                )
            }
        )
    }

    private func unsignedBinding(
        _ integer: PatchRuntimeUnsignedIntegerConfiguration,
        control: PatchRuntimeControlConfiguration,
        keyPath: KeyPath<PatchRuntimeUnsignedIntegerConfiguration, UInt64>
    ) -> Binding<UInt64> {
        Binding(
            get: { integer[keyPath: keyPath] },
            set: { value in
                let replacement = PatchRuntimeUnsignedIntegerConfiguration(
                    defaultValue: keyPath == \.defaultValue ? value : integer.defaultValue,
                    minimumValue: integer.minimumValue,
                    maximumValue: integer.maximumValue,
                    step: keyPath == \.step ? value : integer.step
                )
                update(control.replacingValue(.unsignedInteger(replacement)))
            }
        )
    }

    private func unsignedOptionalBinding(
        _ integer: PatchRuntimeUnsignedIntegerConfiguration,
        control: PatchRuntimeControlConfiguration,
        isMinimum: Bool
    ) -> Binding<UInt64> {
        Binding(
            get: { (isMinimum ? integer.minimumValue : integer.maximumValue) ?? 0 },
            set: { value in
                update(
                    control.replacingValue(
                        .unsignedInteger(
                            PatchRuntimeUnsignedIntegerConfiguration(
                                defaultValue: integer.defaultValue,
                                minimumValue: isMinimum ? value : integer.minimumValue,
                                maximumValue: isMinimum ? integer.maximumValue : value,
                                step: integer.step
                            )
                        )
                    )
                )
            }
        )
    }

    private func update(_ configuration: PatchRuntimeControlConfiguration) {
        model.updateRuntimeControl(for: patch, configuration: configuration)
    }
}

private enum RuntimeControlEditorKind: String {
    case toggle
    case boolean
    case signedInteger
    case unsignedInteger

    var displayName: String {
        switch self {
        case .toggle: "Toggle Patch"
        case .boolean: "Boolean Choice"
        case .signedInteger, .unsignedInteger: "Integer Input"
        }
    }
}

extension PatchRuntimeControlConfiguration {
    func replacing(
        title: String? = nil,
        defaultEnabled: Bool? = nil,
        persistence: PatchRuntimeControlPersistence? = nil
    ) -> PatchRuntimeControlConfiguration {
        PatchRuntimeControlConfiguration(
            title: title ?? self.title,
            defaultEnabled: defaultEnabled ?? self.defaultEnabled,
            persistence: persistence ?? self.persistence,
            order: order,
            value: value
        )
    }

    func replacingValue(_ value: PatchRuntimeControlValue?) -> PatchRuntimeControlConfiguration {
        PatchRuntimeControlConfiguration(
            title: title,
            defaultEnabled: defaultEnabled,
            persistence: persistence,
            order: order,
            value: value
        )
    }
}

private extension PatchRuntimeControlPersistence {
    var displayName: String {
        switch self {
        case .session: "This Launch"
        case .acrossLaunches: "Across Launches"
        }
    }
}
