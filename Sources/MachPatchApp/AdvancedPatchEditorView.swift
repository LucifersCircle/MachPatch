import MachPatchCore
import SwiftUI

struct AdvancedPatchEditorView: View {
    let patch: MethodPatch
    let signature: ObjectiveCMethodSignature
    let updatePatch: (MethodPatch) -> Void

    @State private var isExpanded = false

    private var advanced: PatchAdvancedConfiguration {
        patch.advanced ?? PatchAdvancedConfiguration()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 10)
                    Text("Advanced Behavior")
                        .font(.headline)
                    Spacer(minLength: 4)
                    Text(featureCount == 0 ? "Optional" : "\(featureCount) active")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    counterEditor
                    Divider()
                    argumentEditor
                    Divider()
                    conditionalEditor
                    Divider()
                    effectsEditor(
                        title: "Before Original",
                        explanation: "Runs before the primary action or original method.",
                        effects: advanced.beforeEffects,
                        phase: .before
                    )
                    Divider()
                    effectsEditor(
                        title: "After Original",
                        explanation: patch.action.callsOriginal
                            ? "Runs after the original method and before its result is returned or replaced."
                            : "Choose a primary action that calls the original method to add after-effects.",
                        effects: advanced.afterEffects,
                        phase: .after
                    )
                }
                .padding(.leading, 16)
            }
        }
    }

    private var counterEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Invocation Counter",
                isOn: Binding(
                    get: { advanced.invocationCounter != nil },
                    set: { enabled in
                        replaceAdvanced(
                            invocationCounter: enabled
                                ? .some(PatchInvocationCounter()) : .some(nil)
                        )
                    }
                )
            )
            .disabled(conditionalUsesInvocationCount)
            .help(
                conditionalUsesInvocationCount
                    ? "The conditional return currently depends on this counter."
                    : "Track how many times this method runs."
            )
            if let counter = advanced.invocationCounter {
                Toggle(
                    "Log each count",
                    isOn: Binding(
                        get: { counter.logEachInvocation },
                        set: {
                            replaceAdvanced(
                                invocationCounter: PatchInvocationCounter(logEachInvocation: $0))
                        }
                    )
                )
                .padding(.leading, 18)
                Text(
                    "Maintains a thread-safe count for this method. It can also drive a conditional result."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if counter.logEachInvocation {
                    PatchLoggingSummaryView(payload: "Class, selector, and invocation count")
                        .padding(.leading, 18)
                }
            }
        }
    }

    @ViewBuilder
    private var argumentEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Argument Replacements")
                .font(.subheadline.weight(.semibold))
            if signature.explicitArguments.isEmpty {
                Text("This method has no explicit arguments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !patch.action.callsOriginal {
                Text(
                    "Choose a primary action that calls the original method to replace its arguments."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(Array(signature.explicitArguments.enumerated()), id: \.offset) {
                    index, type in
                    let replacement = advanced.argumentReplacements.first {
                        $0.argumentIndex == index
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        if PatchActionCompatibility.supportsArgumentReplacement(for: type) {
                            Toggle(
                                "Argument \(index + 1) · \(type.displayName)",
                                isOn: Binding(
                                    get: { replacement != nil },
                                    set: {
                                        enabled in setArgument(index, type: type, enabled: enabled)
                                    }
                                )
                            )
                            if let replacement {
                                typedValueEditor(
                                    replacement.value,
                                    type: type,
                                    label: "Replacement"
                                ) { setArgumentValue(index, value: $0) }
                                .padding(.leading, 18)
                            }
                        } else {
                            HStack {
                                Text("Argument \(index + 1) · \(type.displayName)")
                                Spacer()
                                Text("Pass-through only")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var conditionalEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            if signature.returnType.kind == .void {
                Text("Conditional Return")
                    .font(.subheadline.weight(.semibold))
                Text("Unavailable because this method has no return value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !PatchActionCompatibility.supportsConditionalReturn(
                for: signature.returnType
            ) {
                Text("Conditional Return")
                    .font(.subheadline.weight(.semibold))
                Text("Unavailable because this return type supports pass-through only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle(
                    "Conditional Return",
                    isOn: Binding(
                        get: { advanced.conditionalReturn != nil },
                        set: { setConditionalEnabled($0) }
                    ))
                if let conditional = advanced.conditionalReturn {
                    VStack(alignment: .leading, spacing: 9) {
                        Picker(
                            "When",
                            selection: Binding(
                                get: { sourceID(conditional.condition.source) },
                                set: { setConditionSource($0, conditional: conditional) }
                            )
                        ) {
                            ForEach(conditionSources, id: \.id) { source in
                                Text(source.title).tag(source.id)
                            }
                        }

                        Picker(
                            "Comparison",
                            selection: Binding(
                                get: { conditional.condition.comparison },
                                set: { setConditionComparison($0, conditional: conditional) }
                            )
                        ) {
                            ForEach(comparisons(for: conditional.condition.source), id: \.rawValue)
                            {
                                Text($0.displayName).tag($0)
                            }
                        }

                        typedValueEditor(
                            conditional.condition.value,
                            type: type(for: conditional.condition.source),
                            label: "Compare With"
                        ) { setConditionValue($0, conditional: conditional) }

                        returnValueEditor(conditional.replacement, label: "Then Return") {
                            setConditionalReplacement($0, conditional: conditional)
                        }

                        Text(
                            "The condition is checked before argument replacements and the primary action."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 18)
                }
            }
        }
    }

    private func effectsEditor(
        title: String,
        explanation: String,
        effects: [PatchEffect],
        phase: EffectPhase
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Menu {
                    Button("Show Alert", systemImage: "exclamationmark.bubble") {
                        appendEffect(
                            .showAlert(PatchAlert(title: "MachPatch", message: "Method invoked")),
                            phase: phase
                        )
                    }
                    Button(
                        "Custom Objective-C", systemImage: "chevron.left.forwardslash.chevron.right"
                    ) {
                        appendEffect(
                            .customObjectiveC(
                                PatchCustomObjectiveC(
                                    source: "NSLog(@\"[MachPatch] custom code ran\");"
                                )
                            ),
                            phase: phase
                        )
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(phase == .after && !patch.action.callsOriginal)
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(effects.enumerated()), id: \.offset) { index, effect in
                effectEditor(effect, index: index, phase: phase)
                    .padding(10)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func effectEditor(_ effect: PatchEffect, index: Int, phase: EffectPhase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(effect.title, systemImage: effect.systemImage)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(role: .destructive) {
                    removeEffect(index, phase: phase)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove effect")
            }

            switch effect {
            case .showAlert(let alert):
                TextField(
                    "Alert Title",
                    text: effectStringBinding(
                        alert.title,
                        effect: effect,
                        index: index,
                        phase: phase
                    ) {
                        .showAlert(
                            PatchAlert(
                                title: $0, message: alert.message, buttonTitle: alert.buttonTitle))
                    })
                TextField(
                    "Message",
                    text: effectStringBinding(
                        alert.message,
                        effect: effect,
                        index: index,
                        phase: phase
                    ) {
                        .showAlert(
                            PatchAlert(
                                title: alert.title, message: $0, buttonTitle: alert.buttonTitle))
                    })
                TextField(
                    "Button",
                    text: effectStringBinding(
                        alert.buttonTitle,
                        effect: effect,
                        index: index,
                        phase: phase
                    ) {
                        .showAlert(
                            PatchAlert(title: alert.title, message: alert.message, buttonTitle: $0))
                    })
            case .customObjectiveC(let custom):
                TextEditor(
                    text: effectStringBinding(
                        custom.source,
                        effect: effect,
                        index: index,
                        phase: phase
                    ) { .customObjectiveC(PatchCustomObjectiveC(source: $0)) }
                )
                .font(.caption.monospaced())
                .frame(minHeight: 100)
                Text(customCodeHelp(phase))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func typedValueEditor(
        _ value: PatchValue,
        type: ObjectiveCType,
        label: String,
        onChange: @escaping (PatchValue) -> Void
    ) -> some View {
        switch type.kind {
        case .boolean:
            Picker(
                label,
                selection: Binding(
                    get: { if case .boolean(let value) = value { value } else { false } },
                    set: { onChange(.boolean($0)) }
                )
            ) {
                Text("False").tag(false)
                Text("True").tag(true)
            }
            .pickerStyle(.segmented)
        case let kind where kind.isSignedInteger:
            TextField(
                label,
                value: Binding(
                    get: { if case .signedInteger(let value) = value { value } else { 0 } },
                    set: { onChange(.signedInteger($0)) }
                ), format: .number.grouping(.never))
        case let kind where kind.isUnsignedInteger:
            TextField(
                label,
                value: Binding(
                    get: { if case .unsignedInteger(let value) = value { value } else { 0 } },
                    set: { onChange(.unsignedInteger($0)) }
                ), format: .number.grouping(.never))
        case .float, .double:
            TextField(
                label,
                value: Binding(
                    get: { if case .floatingPoint(let value) = value { value } else { 0 } },
                    set: { onChange(.floatingPoint($0)) }
                ), format: .number.grouping(.never))
        case .object:
            Picker(
                "\(label) Type",
                selection: Binding(
                    get: { value.kind.rawValue },
                    set: {
                        onChange($0 == PatchValueKind.string.rawValue ? .string("") : .nilValue)
                    }
                )
            ) {
                Text("nil").tag(PatchValueKind.nilValue.rawValue)
                Text("NSString").tag(PatchValueKind.string.rawValue)
            }
            if case .string(let text) = value {
                TextField(label, text: Binding(get: { text }, set: { onChange(.string($0)) }))
            }
        case .classObject:
            Picker(
                "\(label) Type",
                selection: Binding(
                    get: { value.kind.rawValue },
                    set: {
                        onChange(
                            $0 == PatchValueKind.classNamed.rawValue
                                ? .classNamed("NSObject") : .nilValue)
                    }
                )
            ) {
                Text("Nil").tag(PatchValueKind.nilValue.rawValue)
                Text("Named Class").tag(PatchValueKind.classNamed.rawValue)
            }
            if case .classNamed(let name) = value {
                TextField(label, text: Binding(get: { name }, set: { onChange(.classNamed($0)) }))
            }
        case .selector:
            Picker(
                "\(label) Type",
                selection: Binding(
                    get: { value.kind.rawValue },
                    set: {
                        onChange(
                            $0 == PatchValueKind.selector.rawValue
                                ? .selector("description") : .nilValue)
                    }
                )
            ) {
                Text("NULL").tag(PatchValueKind.nilValue.rawValue)
                Text("Named Selector").tag(PatchValueKind.selector.rawValue)
            }
            if case .selector(let selector) = value {
                TextField(
                    label,
                    text: Binding(get: { selector }, set: { onChange(.selector($0)) }))
            }
        case .pointer:
            Text("NULL pointer")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .block:
            Text("nil block")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            Text("Unsupported value type")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func returnValueEditor(
        _ value: PatchReturnValue,
        label: String,
        onChange: @escaping (PatchReturnValue) -> Void
    ) -> some View {
        switch signature.returnType.kind {
        case .boolean:
            Picker(
                label,
                selection: Binding(
                    get: { if case .boolean(let result) = value { result } else { false } },
                    set: { onChange(.boolean($0)) }
                )
            ) {
                Text("False").tag(false)
                Text("True").tag(true)
            }
            .pickerStyle(.segmented)
        case let kind where kind.isSignedInteger:
            TextField(
                label,
                value: Binding(
                    get: { if case .signedInteger(let result) = value { result } else { 0 } },
                    set: { onChange(.signedInteger($0)) }
                ), format: .number.grouping(.never))
        case let kind where kind.isUnsignedInteger:
            TextField(
                label,
                value: Binding(
                    get: { if case .unsignedInteger(let result) = value { result } else { 0 } },
                    set: { onChange(.unsignedInteger($0)) }
                ), format: .number.grouping(.never))
        case .float, .double:
            TextField(
                label,
                value: Binding(
                    get: { if case .floatingPoint(let result) = value { result } else { 0 } },
                    set: { onChange(.floatingPoint($0)) }
                ), format: .number.grouping(.never))
        case .object:
            Picker(
                "\(label) Type",
                selection: Binding(
                    get: { value.kind.rawValue },
                    set: {
                        onChange(
                            $0 == PatchReturnValueKind.string.rawValue ? .string("") : .nilValue)
                    }
                )
            ) {
                Text("nil").tag(PatchReturnValueKind.nilValue.rawValue)
                Text("NSString").tag(PatchReturnValueKind.string.rawValue)
            }
            if case .string(let text) = value {
                TextField(label, text: Binding(get: { text }, set: { onChange(.string($0)) }))
            }
        case .classObject:
            Picker(
                "\(label) Type",
                selection: Binding(
                    get: { value.kind.rawValue },
                    set: {
                        onChange(
                            $0 == PatchReturnValueKind.classNamed.rawValue
                                ? .classNamed("NSObject") : .nilValue)
                    }
                )
            ) {
                Text("Nil").tag(PatchReturnValueKind.nilValue.rawValue)
                Text("Named Class").tag(PatchReturnValueKind.classNamed.rawValue)
            }
            if case .classNamed(let className) = value {
                TextField(
                    label,
                    text: Binding(get: { className }, set: { onChange(.classNamed($0)) }))
            }
        case .selector:
            Picker(
                "\(label) Type",
                selection: Binding(
                    get: { value.kind.rawValue },
                    set: {
                        onChange(
                            $0 == PatchReturnValueKind.selector.rawValue
                                ? .selector("description") : .nilValue)
                    }
                )
            ) {
                Text("NULL").tag(PatchReturnValueKind.nilValue.rawValue)
                Text("Named Selector").tag(PatchReturnValueKind.selector.rawValue)
            }
            if case .selector(let selector) = value {
                TextField(
                    label,
                    text: Binding(get: { selector }, set: { onChange(.selector($0)) }))
            }
        default:
            EmptyView()
        }
    }

    private var featureCount: Int {
        advanced.argumentReplacements.count + advanced.beforeEffects.count
            + advanced.afterEffects.count + (advanced.conditionalReturn == nil ? 0 : 1)
            + (advanced.invocationCounter == nil ? 0 : 1)
    }

    private var conditionalUsesInvocationCount: Bool {
        advanced.conditionalReturn?.condition.source == .invocationCount
    }

    private func setArgument(_ index: Int, type: ObjectiveCType, enabled: Bool) {
        var replacements = advanced.argumentReplacements.filter { $0.argumentIndex != index }
        if enabled {
            replacements.append(
                PatchArgumentReplacement(argumentIndex: index, value: defaultValue(for: type)))
        }
        replaceAdvanced(
            argumentReplacements: replacements.sorted { $0.argumentIndex < $1.argumentIndex })
    }

    private func setArgumentValue(_ index: Int, value: PatchValue) {
        replaceAdvanced(
            argumentReplacements: advanced.argumentReplacements.map {
                $0.argumentIndex == index
                    ? PatchArgumentReplacement(argumentIndex: index, value: value) : $0
            })
    }

    private func setConditionalEnabled(_ enabled: Bool) {
        guard enabled else {
            replaceAdvanced(conditionalReturn: .some(nil))
            return
        }
        let source = defaultConditionSource
        let conditional = PatchConditionalReturn(
            condition: PatchCondition(
                source: source,
                comparison: .equal,
                value: defaultValue(for: type(for: source))
            ),
            replacement: defaultReturnValue()
        )
        replaceAdvanced(
            conditionalReturn: .some(conditional),
            invocationCounter: source == .invocationCount && advanced.invocationCounter == nil
                ? .some(PatchInvocationCounter(logEachInvocation: false)) : nil
        )
    }

    private func setConditionSource(_ id: String, conditional: PatchConditionalReturn) {
        let source = conditionSource(id)
        let replacement = PatchConditionalReturn(
            condition: PatchCondition(
                source: source,
                comparison: .equal,
                value: defaultValue(for: type(for: source))
            ),
            replacement: conditional.replacement
        )
        replaceAdvanced(
            conditionalReturn: .some(replacement),
            invocationCounter: source == .invocationCount && advanced.invocationCounter == nil
                ? .some(PatchInvocationCounter(logEachInvocation: false)) : nil
        )
    }

    private func setConditionComparison(
        _ comparison: PatchComparison, conditional: PatchConditionalReturn
    ) {
        replaceCondition(conditional, comparison: comparison)
    }

    private func setConditionValue(_ value: PatchValue, conditional: PatchConditionalReturn) {
        replaceAdvanced(
            conditionalReturn: .some(
                PatchConditionalReturn(
                    condition: PatchCondition(
                        source: conditional.condition.source,
                        comparison: conditional.condition.comparison,
                        value: value
                    ),
                    replacement: conditional.replacement
                )))
    }

    private func setConditionalReplacement(
        _ value: PatchReturnValue, conditional: PatchConditionalReturn
    ) {
        replaceAdvanced(
            conditionalReturn: .some(
                PatchConditionalReturn(
                    condition: conditional.condition,
                    replacement: value
                )))
    }

    private func replaceCondition(
        _ conditional: PatchConditionalReturn, comparison: PatchComparison
    ) {
        replaceAdvanced(
            conditionalReturn: .some(
                PatchConditionalReturn(
                    condition: PatchCondition(
                        source: conditional.condition.source,
                        comparison: comparison,
                        value: conditional.condition.value
                    ),
                    replacement: conditional.replacement
                )))
    }

    private func appendEffect(_ effect: PatchEffect, phase: EffectPhase) {
        if phase == .before {
            replaceAdvanced(beforeEffects: advanced.beforeEffects + [effect])
        } else {
            replaceAdvanced(afterEffects: advanced.afterEffects + [effect])
        }
    }

    private func removeEffect(_ index: Int, phase: EffectPhase) {
        if phase == .before {
            var effects = advanced.beforeEffects
            effects.remove(at: index)
            replaceAdvanced(beforeEffects: effects)
        } else {
            var effects = advanced.afterEffects
            effects.remove(at: index)
            replaceAdvanced(afterEffects: effects)
        }
    }

    private func effectStringBinding(
        _ value: String,
        effect: PatchEffect,
        index: Int,
        phase: EffectPhase,
        makeEffect: @escaping (String) -> PatchEffect
    ) -> Binding<String> {
        Binding(get: { value }, set: { replaceEffect(makeEffect($0), at: index, phase: phase) })
    }

    private func replaceEffect(_ effect: PatchEffect, at index: Int, phase: EffectPhase) {
        if phase == .before {
            var effects = advanced.beforeEffects
            effects[index] = effect
            replaceAdvanced(beforeEffects: effects)
        } else {
            var effects = advanced.afterEffects
            effects[index] = effect
            replaceAdvanced(afterEffects: effects)
        }
    }

    private func replaceAdvanced(
        argumentReplacements: [PatchArgumentReplacement]? = nil,
        beforeEffects: [PatchEffect]? = nil,
        afterEffects: [PatchEffect]? = nil,
        conditionalReturn: PatchConditionalReturn?? = nil,
        invocationCounter: PatchInvocationCounter?? = nil
    ) {
        let replacement = PatchAdvancedConfiguration(
            argumentReplacements: argumentReplacements ?? advanced.argumentReplacements,
            beforeEffects: beforeEffects ?? advanced.beforeEffects,
            afterEffects: afterEffects ?? advanced.afterEffects,
            conditionalReturn: conditionalReturn ?? advanced.conditionalReturn,
            invocationCounter: invocationCounter ?? advanced.invocationCounter
        )
        updatePatch(patch.replacingAdvanced(replacement))
    }

    private var conditionSources: [(id: String, title: String)] {
        signature.explicitArguments.enumerated().compactMap {
            guard PatchActionCompatibility.supportsCondition(for: $0.element) else { return nil }
            return (
                "argument:\($0.offset)", "Argument \($0.offset + 1) · \($0.element.displayName)"
            )
        } + [("invocationCount", "Invocation Count")]
    }

    private var defaultConditionSource: PatchConditionSource {
        guard
            let index = signature.explicitArguments.firstIndex(where: {
                PatchActionCompatibility.supportsCondition(for: $0)
            })
        else { return .invocationCount }
        return .argument(index)
    }

    private func sourceID(_ source: PatchConditionSource) -> String {
        switch source {
        case .argument(let index): "argument:\(index)"
        case .invocationCount: "invocationCount"
        }
    }

    private func conditionSource(_ id: String) -> PatchConditionSource {
        guard id.hasPrefix("argument:"), let index = Int(id.dropFirst("argument:".count)) else {
            return .invocationCount
        }
        return .argument(index)
    }

    private func type(for source: PatchConditionSource) -> ObjectiveCType {
        switch source {
        case .argument(let index): signature.explicitArguments[index]
        case .invocationCount: ObjectiveCType(encoding: "Q", kind: .unsignedLongLong)
        }
    }

    private func comparisons(for source: PatchConditionSource) -> [PatchComparison] {
        let kind = type(for: source).kind
        return kind.isSignedInteger || kind.isUnsignedInteger || kind == .float || kind == .double
            ? PatchComparison.allCases : [.equal, .notEqual]
    }

    private func defaultValue(for type: ObjectiveCType) -> PatchValue {
        switch type.kind {
        case .boolean: .boolean(false)
        case let kind where kind.isSignedInteger: .signedInteger(0)
        case let kind where kind.isUnsignedInteger: .unsignedInteger(0)
        case .float, .double: .floatingPoint(0)
        case .object, .classObject, .selector, .pointer, .block: .nilValue
        default: .nilValue
        }
    }

    private func defaultReturnValue() -> PatchReturnValue {
        switch signature.returnType.kind {
        case .boolean: .boolean(false)
        case let kind where kind.isSignedInteger: .signedInteger(0)
        case let kind where kind.isUnsignedInteger: .unsignedInteger(0)
        case .float, .double: .floatingPoint(0)
        case .object: .nilValue
        case .classObject: .classNamed("NSObject")
        case .selector: .selector("description")
        default: .nilValue
        }
    }

    private func customCodeHelp(_ phase: EffectPhase) -> String {
        var names = ["self", "_cmd"] + signature.explicitArguments.indices.map { "argument\($0)" }
        if phase == .after, signature.returnType.kind != .void {
            names.append("originalResult")
        }
        return
            "Expert mode. In-scope values: \(names.joined(separator: ", ")). Build diagnostics report syntax errors."
    }
}

private enum EffectPhase: Equatable {
    case before
    case after
}

private extension PatchEffect {
    var title: String {
        switch self {
        case .showAlert: "Show Alert"
        case .customObjectiveC: "Custom Objective-C"
        }
    }

    var systemImage: String {
        switch self {
        case .showAlert: "exclamationmark.bubble"
        case .customObjectiveC: "chevron.left.forwardslash.chevron.right"
        }
    }
}

private extension ObjectiveCTypeKind {
    var displayName: String {
        switch self {
        case .boolean: "Boolean"
        case let kind where kind.isSignedInteger: "Signed Integer"
        case let kind where kind.isUnsignedInteger: "Unsigned Integer"
        case .float: "Float"
        case .double: "Double"
        case .object: "Object"
        case .classObject: "Class"
        case .selector: "Selector"
        default: rawValue
        }
    }
}

private extension ObjectiveCType {
    var displayName: String {
        knownStructure?.rawValue ?? kind.displayName
    }
}

private extension PatchComparison {
    var displayName: String {
        switch self {
        case .equal: "Equals"
        case .notEqual: "Does Not Equal"
        case .lessThan: "Less Than"
        case .lessThanOrEqual: "Less Than or Equal"
        case .greaterThan: "Greater Than"
        case .greaterThanOrEqual: "Greater Than or Equal"
        }
    }
}
