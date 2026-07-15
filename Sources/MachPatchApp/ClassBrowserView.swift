import MachPatchCore
import SwiftUI

struct ClassBrowserView: View {
    let objectiveCClass: ObjectiveCClass
    @ObservedObject var model: WorkspaceModel

    @State private var methodSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            classHeader
            Divider()
            GeometryReader { geometry in
                let layout = ClassBrowserColumnLayout(availableWidth: geometry.size.width)
                HStack(spacing: 0) {
                    ClassMetadataPanel(objectiveCClass: objectiveCClass)
                        .frame(width: layout.metadataWidth)
                        .clipped()
                    Divider()
                    methodList
                        .frame(width: layout.methodWidth)
                        .clipped()
                    Divider()
                    methodInspector
                        .frame(width: layout.inspectorWidth)
                        .clipped()
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(objectiveCClass.name)
    }

    private var classHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: objectiveCClass.isObjectiveCVisibleSwift ? "swift" : "cube.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(objectiveCClass.name)
                    .font(.title.weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if let superclass = objectiveCClass.superclassName {
                        Text("Subclass of \(superclass)")
                    }
                    if objectiveCClass.isLikelyAppDefined {
                        Text("Likely app-defined")
                            .foregroundStyle(.tint)
                    }
                    if objectiveCClass.isObjectiveCVisibleSwift {
                        Text("Objective-C-visible Swift")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var methodList: some View {
        VStack(spacing: 0) {
            TextField("Search methods", text: $methodSearch)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            List(selection: $model.selectedMethodID) {
                methodSection("Instance Methods", methods: filteredInstanceMethods)
                methodSection("Class Methods", methods: filteredClassMethods)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var methodInspector: some View {
        if let method = selectedMethod {
            MethodInspectorView(
                objectiveCClass: objectiveCClass,
                method: method,
                model: model
            )
        } else {
            ContentUnavailableView(
                "Select a Method",
                systemImage: "function",
                description: Text("Choose an instance or class method to inspect its signature.")
            )
        }
    }

    @ViewBuilder
    private func methodSection(_ title: String, methods: [ObjectiveCMethod]) -> some View {
        if !methods.isEmpty {
            Section("\(title) · \(methods.count)") {
                ForEach(methods) { method in
                    MethodListRow(
                        method: method,
                        isPatched: model.patch(
                            className: objectiveCClass.name,
                            method: method
                        ) != nil
                    )
                    .tag(method.id)
                }
            }
        }
    }

    private var filteredInstanceMethods: [ObjectiveCMethod] {
        filtered(objectiveCClass.instanceMethods)
    }

    private var filteredClassMethods: [ObjectiveCMethod] {
        filtered(objectiveCClass.classMethods)
    }

    private var selectedMethod: ObjectiveCMethod? {
        guard let selectedMethodID = model.selectedMethodID else { return nil }
        return (objectiveCClass.instanceMethods + objectiveCClass.classMethods).first {
            $0.id == selectedMethodID
        }
    }

    private func filtered(_ methods: [ObjectiveCMethod]) -> [ObjectiveCMethod] {
        let query = methodSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return methods }
        return methods.filter {
            $0.selector.localizedCaseInsensitiveContains(query)
                || $0.typeEncoding?.localizedCaseInsensitiveContains(query) == true
        }
    }
}

struct ClassBrowserColumnLayout: Equatable {
    static let dividerWidth: CGFloat = 1

    let metadataWidth: CGFloat
    let methodWidth: CGFloat
    let inspectorWidth: CGFloat

    init(availableWidth: CGFloat) {
        let dividerSpace = Self.dividerWidth * 2
        let contentWidth = max(availableWidth - dividerSpace, 0)
        var metadata = min(max(contentWidth * 0.24, 150), 260)
        var inspector = min(max(contentWidth * 0.30, 200), 340)
        let minimumMethodWidth = min(220, contentWidth)
        let availableForSides = max(contentWidth - minimumMethodWidth, 0)
        let desiredSideWidth = metadata + inspector

        if desiredSideWidth > availableForSides, desiredSideWidth > 0 {
            let scale = availableForSides / desiredSideWidth
            metadata *= scale
            inspector *= scale
        }

        metadataWidth = metadata
        inspectorWidth = inspector
        methodWidth = max(contentWidth - metadata - inspector, 0)
    }

    var totalWidth: CGFloat {
        metadataWidth + methodWidth + inspectorWidth + Self.dividerWidth * 2
    }
}

private struct ClassMetadataPanel: View {
    let objectiveCClass: ObjectiveCClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                metadataSection("Origin") {
                    metadataValue("Image", objectiveCClass.imageName ?? "Unknown")
                    metadataValue("Superclass", objectiveCClass.superclassName ?? "None")
                }

                metadataSection("Protocols · \(objectiveCClass.protocols.count)") {
                    if objectiveCClass.protocols.isEmpty {
                        emptyValue
                    } else {
                        ForEach(objectiveCClass.protocols, id: \.self) { protocolName in
                            Text(protocolName)
                        }
                    }
                }

                metadataSection("Properties · \(objectiveCClass.properties.count)") {
                    if objectiveCClass.properties.isEmpty {
                        emptyValue
                    } else {
                        ForEach(objectiveCClass.properties) { property in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(property.name)
                                Text(property.attributes)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                metadataSection("Ivars · \(objectiveCClass.ivars.count)") {
                    if objectiveCClass.ivars.isEmpty {
                        emptyValue
                    } else {
                        ForEach(objectiveCClass.ivars) { ivar in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ivar.name)
                                Text(ivar.typeEncoding)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .textSelection(.enabled)
        }
    }

    private var emptyValue: some View {
        Text("None")
            .foregroundStyle(.tertiary)
    }

    private func metadataValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func metadataSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

private struct MethodListRow: View {
    let method: ObjectiveCMethod
    let isPatched: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(method.kind == .instance ? "−" : "+")
                .font(.body.monospaced().weight(.bold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(method.selector)
                    .lineLimit(1)
                Text(method.typeEncoding ?? "Type encoding unavailable")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isPatched {
                Image(systemName: "hammer.circle.fill")
                    .foregroundStyle(.tint)
                    .help("This method has a patch draft")
            }
        }
    }
}

private struct MethodInspectorView: View {
    let objectiveCClass: ObjectiveCClass
    let method: ObjectiveCMethod
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(method.kind == .instance ? "Instance Method" : "Class Method")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(method.selector)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                }

                inspectorSection("Raw Type Encoding") {
                    Text(method.typeEncoding ?? "Unavailable")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }

                if let signature {
                    inspectorSection("Decoded Signature") {
                        LabeledContent("Returns", value: describe(signature.returnType))
                        LabeledContent(
                            "Arguments",
                            value: String(signature.explicitArguments.count)
                        )
                        if let frameSize = signature.frameSize {
                            LabeledContent("Frame size", value: String(frameSize))
                        }
                        ForEach(Array(signature.explicitArguments.enumerated()), id: \.offset) {
                            index, argument in
                            LabeledContent("Argument \(index + 1)", value: describe(argument))
                        }
                    }

                    inspectorSection("Patch Editor") {
                        PatchEditorView(
                            objectiveCClass: objectiveCClass,
                            method: method,
                            signature: signature,
                            model: model
                        )
                    }
                } else if method.typeEncoding != nil {
                    inspectorSection("Decoded Signature") {
                        Label(
                            "The type encoding could not be decoded safely.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                if let implementationAddress = method.implementationAddress {
                    inspectorSection("Implementation") {
                        Text("0x\(String(implementationAddress, radix: 16))")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var signature: ObjectiveCMethodSignature? {
        guard let typeEncoding = method.typeEncoding else { return nil }
        return try? ObjectiveCTypeEncodingDecoder.decodeMethodSignature(typeEncoding)
    }

    private func describe(_ type: ObjectiveCType) -> String {
        if let annotation = type.annotation, !annotation.isEmpty {
            return "\(type.kind.rawValue) · \(annotation)"
        }
        return type.kind.rawValue
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

private struct PatchEditorView: View {
    let objectiveCClass: ObjectiveCClass
    let method: ObjectiveCMethod
    let signature: ObjectiveCMethodSignature
    @ObservedObject var model: WorkspaceModel

    @State private var editorError: String?
    @State private var availableActionsExpanded = false
    @State private var unavailableActionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let patch = model.patch(className: objectiveCClass.name, method: method) {
                editor(for: patch)
            } else {
                Button {
                    do {
                        try model.addPatch(className: objectiveCClass.name, method: method)
                        editorError = nil
                    } catch {
                        editorError = error.localizedDescription
                    }
                } label: {
                    Label("Create Patch", systemImage: "hammer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(allowedActions.isEmpty)

                Text(
                    allowedActions.isEmpty
                        ? "This complete method signature is not patchable in version 1."
                        : "MachPatch will create a type-safe patch that records this exact method encoding."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let editorError {
                Label(editorError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !allowedActions.isEmpty {
                actionDisclosure(
                    "Available Actions",
                    isExpanded: $availableActionsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(allowedActions, id: \.rawValue) { kind in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(kind.displayName, systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                                Text(kind.summary)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }

            if !unavailableActions.isEmpty {
                actionDisclosure(
                    "Unavailable Actions",
                    isExpanded: $unavailableActionsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(unavailableActions, id: \.rawValue) { kind in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(kind.displayName, systemImage: "nosign")
                                    .foregroundStyle(.secondary)
                                Text(
                                    PatchActionEditorPolicy.unavailableReason(
                                        for: kind,
                                        signature: signature
                                    ) ?? "Unavailable for this method."
                                )
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func actionDisclosure<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 10)
                    Text(title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(isExpanded.wrappedValue ? "Hide" : "Show") \(title.lowercased())")

            if isExpanded.wrappedValue {
                content()
                    .padding(.leading, 16)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func editor(for patch: MethodPatch) -> some View {
        if !patch.enabled {
            VStack(alignment: .leading, spacing: 6) {
                Label("Disabled Imported Patch", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
                Text("Disabled patches are preserved in imported projects but omitted from builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Enable Patch") {
                    model.updatePatch(patch.replacing(enabled: true))
                }
            }
        }

        Picker(
            "Action",
            selection: Binding(
                get: { patch.action.kind.rawValue },
                set: { rawValue in
                    guard let kind = PatchActionKind(rawValue: rawValue),
                        let action = PatchActionEditorPolicy.action(
                            for: kind,
                            signature: signature
                        )
                    else { return }
                    model.updatePatch(patch.replacing(action: action))
                }
            )
        ) {
            ForEach(allowedActions, id: \.rawValue) { kind in
                Text(kind.displayName)
                    .tag(kind.rawValue)
            }
        }

        actionValueEditor(for: patch)

        if let incompatibility = PatchActionCompatibility.incompatibility(
            action: patch.action,
            signature: signature
        ) {
            Label(incompatibility, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Label(
                "Compatible with \(signature.returnType.kind.rawValue)",
                systemImage: "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.green)
        }

        Text("Patch ID \(patch.id)")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)

        Button("Remove Patch", role: .destructive) {
            model.removePatch(id: patch.id)
        }
    }

    @ViewBuilder
    private func actionValueEditor(for patch: MethodPatch) -> some View {
        switch patch.action {
        case .returnBoolean(let value):
            booleanPicker(
                "Boolean Result",
                value: actionBinding(patch: patch, value: value) { .returnBoolean($0) }
            )
            actionExplanation(
                "The original method is not called. This patch always returns \(value ? "True" : "False")."
            )
        case .returnSignedInteger(let value):
            TextField(
                "Signed Return Value",
                value: actionBinding(patch: patch, value: value) { .returnSignedInteger($0) },
                format: .number.grouping(.never)
            )
            actionExplanation(
                "The original method is not called; this integer is returned instead.")
        case .returnUnsignedInteger(let value):
            TextField(
                "Unsigned Return Value",
                value: actionBinding(patch: patch, value: value) { .returnUnsignedInteger($0) },
                format: .number.grouping(.never)
            )
            actionExplanation(
                "The original method is not called; this integer is returned instead.")
        case .returnString(let value):
            TextField(
                "String Result",
                text: actionBinding(patch: patch, value: value) { .returnString($0) }
            )
            actionExplanation(
                "The original method is not called; this Objective-C string is returned.")
        case .callOriginalAndReplace(let replacement):
            replacementEditor(for: replacement, patch: patch)
            actionExplanation(
                "The original method runs first. Its result is discarded and replaced with the value above."
            )
        case .returnNil:
            actionExplanation("The original method is not called. This patch always returns nil.")
        case .logInvocation:
            actionExplanation(
                "Writes a [MachPatch] NSLog entry containing the class and selector, then calls the original method unchanged. Read it through a LiveContainer console when available, or the device log in macOS Console."
            )
        case .logArguments:
            actionExplanation(
                "Writes [MachPatch] NSLog entries for the invocation and each supported argument, then calls the original method unchanged. Read them through a LiveContainer console when available, or the device log in macOS Console."
            )
        case .logOriginalReturnValue:
            actionExplanation(
                "Calls the original method, writes its result to NSLog with a [MachPatch] prefix, and returns that same result unchanged."
            )
        case .callOriginal:
            actionExplanation(
                "Calls the original method without logging or changing its behavior. This is useful as a safe baseline patch."
            )
        }
    }

    @ViewBuilder
    private func replacementEditor(for replacement: PatchReturnValue, patch: MethodPatch)
        -> some View
    {
        switch replacement {
        case .boolean(let value):
            booleanPicker(
                "Replacement Result",
                value: replacementBinding(patch: patch, value: value) { .boolean($0) }
            )
        case .signedInteger(let value):
            TextField(
                "Replacement Value",
                value: replacementBinding(patch: patch, value: value) { .signedInteger($0) },
                format: .number.grouping(.never)
            )
        case .unsignedInteger(let value):
            TextField(
                "Replacement Value",
                value: replacementBinding(patch: patch, value: value) { .unsignedInteger($0) },
                format: .number.grouping(.never)
            )
        case .string(let value):
            TextField(
                "Replacement String",
                text: replacementBinding(patch: patch, value: value) { .string($0) }
            )
        case .nilValue:
            Text("The original implementation is called, then its result is replaced with nil.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func booleanPicker(_ title: String, value: Binding<Bool>) -> some View {
        Picker(title, selection: value) {
            Text("False").tag(false)
            Text("True").tag(true)
        }
        .pickerStyle(.segmented)
    }

    private func actionExplanation(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actionBinding<Value>(
        patch: MethodPatch,
        value: Value,
        makeAction: @escaping (Value) -> PatchAction
    ) -> Binding<Value> {
        Binding(
            get: { value },
            set: { model.updatePatch(patch.replacing(action: makeAction($0))) }
        )
    }

    private func replacementBinding<Value>(
        patch: MethodPatch,
        value: Value,
        makeReplacement: @escaping (Value) -> PatchReturnValue
    ) -> Binding<Value> {
        Binding(
            get: { value },
            set: {
                model.updatePatch(
                    patch.replacing(action: .callOriginalAndReplace(makeReplacement($0)))
                )
            }
        )
    }

    private var allowedActions: [PatchActionKind] {
        PatchActionCompatibility.allowedActions(for: signature)
    }

    private var unavailableActions: [PatchActionKind] {
        PatchActionKind.allCases.filter { !allowedActions.contains($0) }
    }
}

extension PatchActionKind {
    var displayName: String {
        switch self {
        case .returnBoolean: "Return Boolean"
        case .returnSignedInteger: "Return Signed Integer"
        case .returnUnsignedInteger: "Return Unsigned Integer"
        case .returnNil: "Return Nil"
        case .returnString: "Return String"
        case .logInvocation: "Log Invocation"
        case .logArguments: "Log Arguments"
        case .logOriginalReturnValue: "Log Original Return Value"
        case .callOriginal: "Call Original"
        case .callOriginalAndReplace: "Call Original and Replace Result"
        }
    }

    var summary: String {
        switch self {
        case .returnBoolean: "Replace the method with a constant True or False result."
        case .returnSignedInteger: "Return a constant signed integer without calling the original."
        case .returnUnsignedInteger:
            "Return a constant unsigned integer without calling the original."
        case .returnNil: "Return nil without calling the original."
        case .returnString: "Return a constant Objective-C string without calling the original."
        case .logInvocation: "Log the class and selector, then call the original unchanged."
        case .logArguments: "Log supported arguments, then call the original unchanged."
        case .logOriginalReturnValue: "Call the original, log its result, and return it unchanged."
        case .callOriginal: "Call the original without logging or changing its result."
        case .callOriginalAndReplace: "Call the original, then discard and replace its result."
        }
    }
}
