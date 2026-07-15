import MachPatchBuilder
import MachPatchCore
import MachPatchGenerator
import SwiftUI

struct BuildWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { proxy in
                let layout = BuildWorkspaceColumnLayout(availableWidth: proxy.size.width)
                HStack(spacing: 0) {
                    settingsPanel
                        .frame(width: layout.settingsWidth)
                    Divider()
                    sourcePanel
                        .frame(width: layout.sourceWidth)
                }
            }
        }
        .navigationTitle("Build Workspace")
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 54, height: 54)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.projectDraft?.projectName ?? "Patch Project")
                    .font(.title2.weight(.semibold))
                Text("Configure the dylib and inspect the exact generated source before building.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let projectDraft = model.projectDraft {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(projectDraft.patches.filter(\.enabled).count) enabled")
                        .font(.headline)
                    Text("\(projectDraft.patches.count) total patches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                projectSettings
                architectureSummary
                validationSummary
            }
            .padding(20)
        }
    }

    private var projectSettings: some View {
        GroupBox("Project & Build Settings") {
            VStack(alignment: .leading, spacing: 14) {
                settingField("Project Name") {
                    TextField(
                        "Patch project",
                        text: Binding(
                            get: { model.projectDraft?.projectName ?? "" },
                            set: { model.updateProjectName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                settingField("Output") {
                    HStack(spacing: 5) {
                        TextField(
                            "PatchLibrary",
                            text: Binding(
                                get: { model.projectDraft?.outputName ?? "" },
                                set: { model.updateOutputName($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Text(".dylib")
                            .foregroundStyle(.secondary)
                    }
                }

                settingField("Architecture") {
                    Picker(
                        "Architecture",
                        selection: Binding(
                            get: { model.projectDraft?.architectureMode ?? .automatic },
                            set: { model.updateArchitectureMode($0) }
                        )
                    ) {
                        ForEach(model.availableArchitectureModes, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                settingField("Minimum iOS") {
                    TextField(
                        "15.0",
                        text: Binding(
                            get: { model.projectDraft?.minimumIOSVersion ?? "" },
                            set: { model.updateMinimumIOSVersion($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Toggle(
                    "Enable Automatic Reference Counting (ARC)",
                    isOn: Binding(
                        get: { model.projectDraft?.enableARC ?? true },
                        set: { model.updateARCEnabled($0) }
                    )
                )
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var architectureSummary: some View {
        GroupBox("Resolved Architecture") {
            switch model.architecturePreview {
            case .unavailable:
                Text("Choose and analyze a target architecture first.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            case .resolved(let resolution):
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Output", value: resolution.outputArchitecture.displayName)
                    LabeledContent(
                        "Slices", value: resolution.slices.map(\.rawValue).joined(separator: ", "))
                    Text(resolution.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var validationSummary: some View {
        if let report = model.projectValidationReport {
            GroupBox("Validation") {
                if report.isValid {
                    Label(
                        "Project settings and patches are valid.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(report.errors.enumerated()), id: \.offset) { _, issue in
                            Label(issue.message, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
        }
    }

    private var sourcePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Generated Source")
                    .font(.headline)
                Spacer()
                if case .ready(let bundle) = model.generatedSourcePreview,
                    let sourceFile = bundle.files.first
                {
                    Text(sourceMetadata(sourceFile))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Divider()

            switch model.generatedSourcePreview {
            case .unavailable(let message):
                ContentUnavailableView(
                    "Source Preview Unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(message)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let bundle):
                if let sourceFile = bundle.files.first {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "doc.plaintext")
                            Text(sourceFile.relativePath)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("Read-only · generated from project JSON")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        Divider()
                        ScrollView([.horizontal, .vertical]) {
                            Text(sourceFile.contents)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                    }
                }
            }
        }
    }

    private func settingField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func sourceMetadata(_ file: GeneratedSourceFile) -> String {
        let lineCount = file.contents.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        return "\(lineCount) lines · \(file.contents.utf8.count) bytes"
    }
}

struct BuildWorkspaceColumnLayout: Equatable {
    private static let dividerWidth: CGFloat = 1

    let availableWidth: CGFloat
    let settingsWidth: CGFloat
    let sourceWidth: CGFloat

    init(availableWidth: CGFloat) {
        self.availableWidth = max(availableWidth, 0)
        let contentWidth = max(self.availableWidth - Self.dividerWidth, 0)
        let preferredSettingsWidth = min(max(contentWidth * 0.36, 300), 400)
        settingsWidth = min(preferredSettingsWidth, contentWidth)
        sourceWidth = max(contentWidth - settingsWidth, 0)
    }

    var totalWidth: CGFloat {
        settingsWidth + Self.dividerWidth + sourceWidth
    }
}

private extension PatchArchitectureMode {
    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .arm64: "arm64"
        case .arm64e: "arm64e"
        case .universal: "Universal (arm64 + arm64e)"
        }
    }
}

private extension PatchBuildOutputArchitecture {
    var displayName: String {
        switch self {
        case .arm64: "arm64"
        case .arm64e: "arm64e"
        case .universal: "Universal"
        }
    }
}
