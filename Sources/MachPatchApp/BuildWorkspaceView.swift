import AppKit
import MachPatchBuilder
import MachPatchCore
import MachPatchGenerator
import MachPatchVerifier
import SwiftUI

struct BuildWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var enabledPatchesExpanded = true
    @State private var disabledPatchesExpanded = false
    @State private var generatedSourceExpanded = true

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
            workspaceHeaderIcon
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

    @ViewBuilder
    private var workspaceHeaderIcon: some View {
        if let iconData = model.targetIconData {
            TargetIconView(iconData: iconData, size: 54)
        } else {
            Image(systemName: "hammer.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 54, height: 54)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                projectSettings
                if model.projectDraft != nil {
                    runtimeControlProjectSettings
                }
                architectureSummary
                validationSummary
                buildPanel
                verificationPanel
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
        .disabled(model.buildState.isBuilding)
    }

    private var runtimeControlProjectSettings: some View {
        GroupBox("In-App Controls") {
            VStack(alignment: .leading, spacing: 12) {
                Picker(
                    "Activation",
                    selection: Binding(
                        get: {
                            model.projectDraft?.runtimeControls?.activationMode ?? .floatingButton
                        },
                        set: { model.updateRuntimeControlActivationMode($0) }
                    )
                ) {
                    ForEach(PatchRuntimeControlActivationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Divider()

                HStack {
                    Text("Available Patches")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(runtimeControlledPatches.count) selected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if !runtimeControlSelectionPatches.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(runtimeControlSelectionPatches) { patch in
                            Toggle(
                                isOn: Binding(
                                    get: { patch.enabled && patch.runtimeControl != nil },
                                    set: { model.setRuntimeControlExposed($0, for: patch) }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(methodDescription(patch))
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(
                                        patch.enabled
                                            ? patch.behaviorSummary
                                            : patch.runtimeControl == nil
                                                ? "Disabled in project · unavailable for in-app controls"
                                                : "Disabled in project · control preserved until re-enabled"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    if patch.runtimeControl != nil {
                                        Text("In app · Patch or Original")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.tint)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!patch.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(nsColor: .controlBackgroundColor).opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                } else {
                    Text("Create a method patch to make it available here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(
                    "Selected patches are remembered automatically. The generated overlay becomes part of the target app UI; gesture activation is never installed while VoiceOver is active."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
        .disabled(model.buildState.isBuilding)
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
        GeometryReader { proxy in
            let layout = BuildWorkspaceRightPanelLayout(availableHeight: proxy.size.height)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    collapsibleHeader(
                        "Enabled Patches",
                        detail: "\(enabledPatches.count) enabled",
                        systemImage: "hammer.circle",
                        isExpanded: $enabledPatchesExpanded
                    )
                    Divider()
                    if enabledPatchesExpanded {
                        patchList(
                            enabledPatches,
                            emptyTitle: "No Enabled Patches",
                            emptyDescription:
                                "Create or enable a method patch to include it in the dylib."
                        )
                        Divider()
                    }

                    collapsibleHeader(
                        "Disabled Patches",
                        detail: "\(disabledPatches.count) disabled",
                        systemImage: "pause.circle",
                        isExpanded: $disabledPatchesExpanded
                    )
                    Divider()
                    if disabledPatchesExpanded {
                        patchList(
                            disabledPatches,
                            emptyTitle: "No Disabled Patches",
                            emptyDescription:
                                "Disable a patch to preserve it without including it in builds."
                        )
                        Divider()
                    }

                    collapsibleHeader(
                        "Generated Source",
                        detail: generatedSourceMetadata,
                        systemImage: "doc.plaintext",
                        isExpanded: $generatedSourceExpanded
                    )
                    Divider()

                    if generatedSourceExpanded {
                        generatedSourceContent
                            .frame(height: layout.generatedSourceHeight)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(
                    minWidth: proxy.size.width,
                    minHeight: proxy.size.height,
                    alignment: .top
                )
            }
        }
    }

    private var enabledPatches: [MethodPatch] {
        model.projectDraft?.patches.filter(\.enabled) ?? []
    }

    private var disabledPatches: [MethodPatch] {
        model.projectDraft?.patches.filter { !$0.enabled } ?? []
    }

    private var runtimeControlledPatches: [MethodPatch] {
        model.projectDraft?.patches.filter { $0.enabled && $0.runtimeControl != nil } ?? []
    }

    private var runtimeControlSelectionPatches: [MethodPatch] {
        guard let patches = model.projectDraft?.patches else { return [] }
        return patches.enumerated().sorted { lhs, rhs in
            if lhs.element.enabled != rhs.element.enabled {
                return lhs.element.enabled
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    @ViewBuilder
    private func patchList(
        _ patches: [MethodPatch],
        emptyTitle: String,
        emptyDescription: String
    ) -> some View {
        if patches.isEmpty {
            VStack(spacing: 7) {
                Label(emptyTitle, systemImage: "hammer")
                    .font(.headline)
                Text(emptyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(patches) { patch in
                    patchRow(patch)
                    if patch.id != patches.last?.id {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        }
    }

    private func patchRow(_ patch: MethodPatch) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                model.inspectPatch(patch)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: patch.enabled ? "hammer.circle.fill" : "pause.circle.fill")
                        .font(.title3)
                        .foregroundStyle(patch.enabled ? Color.accentColor : .secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(methodDescription(patch))
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text(patch.behaviorSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let control = patch.runtimeControl {
                            Label(
                                "In-App Control · \(control.title)",
                                systemImage: "switch.2"
                            )
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(patch.expectedTypeEncoding)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this patch in its class and method editor.")

            HStack(spacing: 6) {
                Button {
                    model.updatePatch(patch.replacing(enabled: !patch.enabled))
                } label: {
                    Label(
                        patch.enabled ? "Disable" : "Enable",
                        systemImage: patch.enabled ? "pause.fill" : "play.fill"
                    )
                }
                .help(
                    patch.enabled
                        ? "Keep this patch and its settings, but omit it from builds."
                        : "Include this preserved patch in generated source and builds."
                )

                Button(role: .destructive) {
                    model.requestDeletePatch(patch)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Permanently remove this method patch from the current project.")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var generatedSourceContent: some View {
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
                    GeneratedSourceTextView(source: sourceFile.contents)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                }
            }
        }
    }

    private var generatedSourceMetadata: String {
        guard case .ready(let bundle) = model.generatedSourcePreview,
            let sourceFile = bundle.files.first
        else { return "Unavailable" }
        return sourceMetadata(sourceFile)
    }

    private func collapsibleHeader(
        _ title: String,
        detail: String,
        systemImage: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func methodDescription(_ patch: MethodPatch) -> String {
        let marker = patch.methodKind == .instance ? "−" : "+"
        return "\(marker)[\(patch.className) \(patch.selector)]"
    }

    private var buildPanel: some View {
        GroupBox("Build Dylib") {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    model.buildDylib()
                } label: {
                    Label(buildButtonTitle, systemImage: "hammer.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canBuild)

                switch model.buildState {
                case .idle:
                    Text(
                        "Builds in an isolated temporary workspace using the selected Xcode iPhoneOS toolchain."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .building(let progress, let previousArtifact):
                    buildProgress(progress)
                    if previousArtifact != nil {
                        Text(
                            "The previous successful dylib remains available until this rebuild succeeds."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                case .succeeded(let artifact):
                    buildArtifactSummary(artifact, isStale: false)
                case .stale(let artifact):
                    buildArtifactSummary(artifact, isStale: true)
                case .failed(let failure, let previousArtifact):
                    buildFailureSummary(failure, previousArtifact: previousArtifact)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var buildButtonTitle: String {
        switch model.buildState {
        case .building:
            "Building…"
        case .succeeded, .failed, .stale:
            "Rebuild Dylib"
        case .idle:
            "Build Dylib"
        }
    }

    private func buildProgress(_ progress: PatchBuildProgress) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: progress.fractionCompleted)
            Text(progress.message)
                .font(.subheadline.weight(.medium))
            Text(
                "Step \(min(progress.completedUnitCount + 1, progress.totalUnitCount)) of \(progress.totalUnitCount)"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func buildArtifactSummary(
        _ artifact: PatchBuildArtifact,
        isStale: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(
                isStale ? "Rebuild Required" : "Build Succeeded",
                systemImage: isStale ? "clock.badge.exclamationmark" : "checkmark.circle.fill"
            )
            .foregroundStyle(isStale ? .orange : .green)

            if isStale {
                Text(
                    "The project changed after this dylib was built. The artifact is preserved, but verification and export will require a rebuild."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "Stored privately for this session while LiveContainer verification runs.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            LabeledContent("Output", value: artifact.dylibURL.lastPathComponent)
            LabeledContent("Architecture", value: artifact.record.architecture.displayName)
            LabeledContent("Minimum iOS", value: artifact.record.minimumIOSVersion)
            LabeledContent("Xcode", value: firstLine(of: artifact.record.toolchain.xcodeVersion))
            LabeledContent("iPhoneOS SDK", value: artifact.record.toolchain.sdkVersion)

            DisclosureGroup("Build Commands & Output") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(artifact.record.slices, id: \.architecture) { slice in
                        commandExecutionSummary(
                            title: "Compile \(slice.architecture.rawValue)",
                            execution: slice.compilation
                        )
                    }
                    if let merge = artifact.record.merge {
                        commandExecutionSummary(title: "Merge universal dylib", execution: merge)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var verificationPanel: some View {
        GroupBox("Verify & Export") {
            VStack(alignment: .leading, spacing: 12) {
                switch model.verificationState {
                case .idle:
                    Label(
                        "Build a dylib to run the LiveContainer compatibility checks.",
                        systemImage: "checkmark.shield"
                    )
                    .foregroundStyle(.secondary)
                case .verifying:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Verifying Dylib…")
                                .font(.subheadline.weight(.semibold))
                            Text(
                                "Checking architecture, platform, install name, dependencies, symbols, paths, and target compatibility."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                case .unavailable(let message):
                    Label(message, systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                case .failed(let failure):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Verification Couldn’t Run", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                case .verified(let report):
                    verificationReport(report)
                }

                HStack(spacing: 8) {
                    Button {
                        model.exportDylib()
                    } label: {
                        Label("Export Dylib…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canExportDylib)
                    .help(exportHelpText)

                    shareButton(for: .dylib)
                }

                Divider()

                Text("Optional Formats")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 8) {
                    Button {
                        model.exportSourceBundle()
                    } label: {
                        Label("Export Source Bundle (.zip)…", systemImage: "doc.zipper")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canExportSourceBundle)
                    .help(
                        model.canExportSourceBundle
                            ? "Export patch.json, deterministic generated source, and an Xcode rebuild script."
                            : "A fresh successful build is required before source export."
                    )

                    shareButton(for: .sourceBundle)
                }

                Text(
                    "A portable archive containing the canonical patch project, generated Objective-C, target identity, and a standalone build script."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        model.exportDebianPackage()
                    } label: {
                        Label("Export .deb…", systemImage: "shippingbox")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canExportDebianPackage)
                    .help(
                        model.debianExportUnavailableReason
                            ?? "Package the verified arm64 dylib with its MobileSubstrate filter plist."
                    )

                    shareButton(for: .debianPackage)
                }

                Text(
                    model.debianExportUnavailableReason
                        ?? "For jailbreak package managers; the plain dylib remains the recommended LiveContainer output."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private func shareButton(for kind: WorkspaceExportKind) -> some View {
        if let completedExport = model.shareableArtifact(for: kind) {
            ShareLink(item: completedExport.url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .help("Share \(completedExport.url.lastPathComponent) using macOS.")
        } else {
            Button {
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help("Export this format before sharing it.")
        }
    }

    private func verificationReport(_ report: DylibVerificationReport) -> some View {
        let passedCount = report.checks.count { $0.status == .passed }
        let warningCount = report.checks.count { $0.status == .warning }
        let failedCount = report.checks.count { $0.status == .failed }

        return VStack(alignment: .leading, spacing: 10) {
            Label(
                report.isReadyForLiveContainerTesting
                    ? "Ready for LiveContainer Testing" : "Export Blocked",
                systemImage: report.isReadyForLiveContainerTesting
                    ? "checkmark.shield.fill" : "xmark.shield.fill"
            )
            .font(.headline)
            .foregroundStyle(report.isReadyForLiveContainerTesting ? .green : .red)

            HStack(spacing: 12) {
                verificationCount(passedCount, title: "Passed", color: .green)
                if warningCount > 0 {
                    verificationCount(warningCount, title: "Warnings", color: .orange)
                }
                if failedCount > 0 {
                    verificationCount(failedCount, title: "Failed", color: .red)
                }
            }

            DisclosureGroup("Verification Checks") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                        verificationCheck(check)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func verificationCount(_ count: Int, title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(String(count))
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption)
        }
        .foregroundStyle(color)
    }

    private func verificationCheck(_ check: VerificationCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: check.status.systemImage)
                .foregroundStyle(check.status.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.code.displayName)
                    .font(.caption.weight(.semibold))
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var exportHelpText: String {
        if model.canExportDylib {
            return "Choose where to save the verified dylib."
        }
        if case .verified(let report) = model.verificationState,
            !report.isReadyForLiveContainerTesting
        {
            return "Export is blocked until every failed verification check is resolved."
        }
        return "A fresh, successfully verified build is required before export."
    }

    private func buildFailureSummary(
        _ failure: PatchBuildFailure,
        previousArtifact: PatchBuildArtifact?
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Build Failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(failure.message)
                .font(.caption)
                .textSelection(.enabled)

            if previousArtifact != nil {
                Label(
                    "The last successful dylib was preserved and is now stale.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            DisclosureGroup("Compiler & Toolchain Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    if let status = failure.terminationStatus {
                        LabeledContent("Exit Status", value: String(status))
                    }
                    if let command = failure.command {
                        Text("Command")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        diagnosticText(command)
                    }
                    Text("Diagnostic Output")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    diagnosticText(failure.diagnosticText)
                }
                .padding(.top, 8)
            }
        }
    }

    private func commandExecutionSummary(
        title: String,
        execution: BuildCommandExecution
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(execution.durationMilliseconds) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            diagnosticText(execution.invocation.displayString)
            let output =
                execution.standardError.isEmpty
                ? execution.standardOutput : execution.standardError
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnosticText(output)
            }
        }
    }

    private func diagnosticText(_ value: String) -> some View {
        ScrollView(.horizontal) {
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(7)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func firstLine(of value: String) -> String {
        value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
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

private extension PatchRuntimeControlActivationMode {
    var displayName: String {
        switch self {
        case .floatingButton: "Floating Button"
        case .threeFingerHold: "Three-Finger Hold"
        case .both: "Button and Gesture"
        }
    }
}

private struct GeneratedSourceTextView: NSViewRepresentable {
    let source: String

    final class Coordinator {
        var displayedSource = ""
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = source
        context.coordinator.displayedSource = source
        scrollView.documentView = textView
        scrollToBeginning(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.displayedSource != source,
            let textView = scrollView.documentView as? NSTextView
        else { return }
        context.coordinator.displayedSource = source
        textView.string = source
        scrollToBeginning(scrollView)
    }

    private func scrollToBeginning(_ scrollView: NSScrollView) {
        DispatchQueue.main.async {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
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

struct BuildWorkspaceRightPanelLayout: Equatable {
    let availableHeight: CGFloat
    let generatedSourceHeight: CGFloat

    init(availableHeight: CGFloat) {
        self.availableHeight = max(availableHeight, 0)
        generatedSourceHeight = max(self.availableHeight * 0.62, 420)
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

private extension VerificationCheckStatus {
    var systemImage: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

private extension VerificationCheckCode {
    var displayName: String {
        switch self {
        case .fileType: "Dynamic Library"
        case .architecture: "Architecture"
        case .lipoAgreement: "Architecture Cross-check"
        case .platform: "iPhoneOS Platform"
        case .deploymentTarget: "Deployment Target"
        case .installName: "Install Name"
        case .dependency: "Dependencies"
        case .unresolvedSymbols: "Unresolved Symbols"
        case .targetCompatibility: "Target Compatibility"
        case .forbiddenFilesystemPath: "Filesystem Paths"
        }
    }
}
