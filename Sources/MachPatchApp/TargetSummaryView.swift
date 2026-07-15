import MachPatchBuilder
import MachPatchCore
import SwiftUI

struct TargetSummaryView: View {
    let loadedTarget: LoadedTarget

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                targetDetails
                selectedImageDetails
                architectureDetails
                analysisDetails
                if let report = loadedTarget.patchabilityReport {
                    patchabilityDetails(report)
                }
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(28)
        }
        .navigationTitle(displayName)
    }

    private func patchabilityDetails(_ report: ObjectiveCPatchabilityReport) -> some View {
        let summary = report.summary
        return GroupBox("Patchability") {
            VStack(alignment: .leading, spacing: 14) {
                Label(
                    "\(summary.patchableClassMethodCount) method declarations are available in the editor",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                    patchabilityRow("All declarations", summary.methodCount)
                    patchabilityRow("Class declarations", summary.classMethodCount)
                    patchabilityRow("Category declarations", summary.categoryMethodCount)
                    patchabilityRow(
                        "Patchable category opportunities",
                        summary.patchableCategoryMethodCount
                    )
                    patchabilityRow("Unavailable declarations", summary.unavailableMethodCount)
                }

                if !summary.issueCounts.isEmpty {
                    Divider()
                    Text("Why declarations are unavailable")
                        .font(.headline)
                    ForEach(summary.issueCounts, id: \.code) { issue in
                        HStack {
                            Text(issue.code.displayName)
                            Spacer()
                            Text(issue.count, format: .number)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                if !summary.unsupportedTypeCounts.isEmpty {
                    Divider()
                    Text("Most common unsupported ABI types")
                        .font(.headline)
                    ForEach(
                        Array(summary.unsupportedTypeCounts.prefix(8).enumerated()),
                        id: \.offset
                    ) { _, item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    "\(unsupportedTypeRole(item.role)) · \(item.typeKind.rawValue)")
                                Text(item.typeEncoding)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Text(item.count, format: .number)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Text(
                    "Counts describe metadata declarations. Compatible category methods are browsable under Category Targets in the sidebar."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private func patchabilityRow(_ label: String, _ count: Int) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 230, alignment: .leading)
            Text(count, format: .number)
                .monospacedDigit()
        }
    }

    private func unsupportedTypeRole(_ role: ObjectiveCUnsupportedTypeRole) -> String {
        switch role {
        case .returnValue:
            "Return"
        case .argument:
            "Argument"
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            TargetIconView(iconData: loadedTarget.iconData, size: 62)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.largeTitle.weight(.semibold))
                Text(loadedTarget.inputURL.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Selected image: \(selectedImageDisplayName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var targetDetails: some View {
        GroupBox("Host Target") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                detailRow("Input type", loadedTarget.target.sourceType.rawValue.uppercased())
                detailRow("Executable", loadedTarget.target.executableName)
                detailRow(
                    "Bundle identifier", loadedTarget.target.bundleIdentifier ?? "Not available")
                detailRow("Minimum iOS", loadedTarget.target.minimumOSVersion ?? "Not declared")
                detailRow(
                    "Platforms",
                    loadedTarget.target.supportedPlatforms.isEmpty
                        ? "Not declared"
                        : loadedTarget.target.supportedPlatforms.joined(separator: ", ")
                )
                detailRow("SHA-256", loadedTarget.target.sha256, monospaced: true)
                detailRow("Source", loadedTarget.inputURL.path, monospaced: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    private var selectedImageDetails: some View {
        let image = loadedTarget.inspection.image
        let slices = loadedTarget.inspection.slices
        let architectures = Array(Set(slices.map(\.architecture.rawValue))).sorted()
        let encryption: String
        if slices.isEmpty {
            encryption = "Not available"
        } else if slices.contains(where: \.encrypted) {
            encryption = "Encrypted"
        } else {
            encryption = "Not encrypted"
        }

        return GroupBox("Selected Image") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                detailRow("Kind", imageKindName(image.kind))
                detailRow("Executable", image.executableName)
                detailRow("Relative path", image.relativePath, monospaced: true)
                detailRow("Bundle identifier", image.bundleIdentifier ?? "Not available")
                detailRow(
                    "Bundle metadata",
                    image.hasBundleMetadata ? "Available" : "Not available"
                )
                detailRow("Minimum iOS", image.minimumOSVersion ?? "Not declared")
                detailRow(
                    "Architectures",
                    architectures.isEmpty ? "Not available" : architectures.joined(separator: ", ")
                )
                detailRow("Encryption", encryption)
                detailRow("SHA-256", image.sha256, monospaced: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    private var architectureDetails: some View {
        GroupBox("Selected Image Architectures") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(loadedTarget.architectureReport.slices, id: \.index) { slice in
                    ArchitectureRow(slice: slice)
                    if slice.index != loadedTarget.architectureReport.slices.last?.index {
                        Divider()
                    }
                }

                Divider()
                Label(
                    loadedTarget.architectureReport.automaticReason,
                    systemImage: "wand.and.stars"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var analysisDetails: some View {
        GroupBox("Objective-C Analysis") {
            switch loadedTarget.analysisState {
            case .loaded(let analysis):
                let methodCount = analysis.metadata.classes.reduce(into: 0) { count, item in
                    count += item.instanceMethods.count + item.classMethods.count
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "Loaded \(analysis.metadata.classes.count) classes and \(methodCount) methods",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    LabeledContent("Selected slice", value: String(analysis.sliceIndex))
                    LabeledContent("Image", value: analysis.image.executableName)
                    LabeledContent("Architecture", value: analysis.architecture.rawValue)
                    LabeledContent("Metadata backend", value: analysis.backend.rawValue)
                    ForEach(analysis.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            case .requiresSliceSelection:
                analysisMessage(
                    "Choose a supported architecture in the sidebar before browsing classes.",
                    systemImage: "cursorarrow.click"
                )
            case .loading(let sliceIndex):
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Analyzing Objective-C metadata in slice \(sliceIndex)…")
                }
                .padding(.vertical, 8)
            case .failed(_, let message):
                analysisMessage(message, systemImage: "exclamationmark.triangle.fill", color: .red)
            case .unavailable(let reason):
                analysisMessage(reason, systemImage: "nosign", color: .secondary)
            }
        }
    }

    private func analysisMessage(
        _ message: String,
        systemImage: String,
        color: Color = .secondary
    ) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private var displayName: String {
        loadedTarget.target.displayName ?? loadedTarget.target.executableName
    }

    private var selectedImageDisplayName: String {
        loadedTarget.inspection.image.displayName ?? loadedTarget.inspection.image.executableName
    }

    private func imageKindName(_ kind: ResolvedImageKind) -> String {
        switch kind {
        case .mainExecutable: "Main executable"
        case .dynamicFramework: "Dynamic framework"
        case .appExtension: "App extension"
        case .standaloneFramework: "Standalone framework"
        case .standaloneMachO: "Standalone Mach-O"
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View
    {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            if monospaced {
                Text(value)
                    .font(.system(.body, design: .monospaced))
            } else {
                Text(value)
            }
        }
    }
}

private struct ArchitectureRow: View {
    let slice: TargetArchitectureSliceAssessment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: slice.supportedForPatching
                    ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(slice.supportedForPatching ? .green : .red)
            .font(.title3)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(slice.architecture.rawValue)
                        .font(.headline)
                    Text(slice.platform.rawValue)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                Text(slice.diagnostic)
                    .foregroundStyle(.secondary)
                Text(
                    "Slice \(slice.index) · CPU subtype \(slice.cpuSubtype) · base \(slice.cpuSubtypeBase)"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}
