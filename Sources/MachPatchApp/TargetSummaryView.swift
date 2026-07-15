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
                architectureDetails
                analysisDetails
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(28)
        }
        .navigationTitle(displayName)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "app.dashed")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 62, height: 62)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.largeTitle.weight(.semibold))
                Text(loadedTarget.inputURL.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var targetDetails: some View {
        GroupBox("Target Summary") {
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

    private var architectureDetails: some View {
        GroupBox("Architectures") {
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
