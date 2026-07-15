import MachPatchCore
import SwiftUI

struct ClassBrowserView: View {
    let objectiveCClass: ObjectiveCClass

    @State private var methodSearch = ""
    @State private var selectedMethodID: String?

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
            List(selection: $selectedMethodID) {
                methodSection("Instance Methods", methods: filteredInstanceMethods)
                methodSection("Class Methods", methods: filteredClassMethods)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var methodInspector: some View {
        if let method = selectedMethod {
            MethodInspectorView(method: method)
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
                    MethodListRow(method: method)
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
        guard let selectedMethodID else { return nil }
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
        }
    }
}

private struct MethodInspectorView: View {
    let method: ObjectiveCMethod

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

                    inspectorSection("Compatible Actions") {
                        let actions = PatchActionCompatibility.allowedActions(for: signature)
                        if actions.isEmpty {
                            Text("No version 1 action supports this complete ABI signature.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(actions, id: \.rawValue) { action in
                                Label(action.rawValue, systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                            }
                        }
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
