import SwiftUI

struct PatchLoggingSummaryView: View {
    let payload: String
    var mayContainSensitiveValues = false

    var body: some View {
        GroupBox("Logging Output") {
            VStack(alignment: .leading, spacing: 7) {
                loggingRow("Destination", value: "Target process system log (NSLog)")
                loggingRow("Severity", value: "Default · fixed")
                loggingRow("Prefix", value: "[MachPatch]")
                loggingRow("Payload", value: payload)

                Text(
                    "View in macOS Console filtered by the target process. A LiveContainer console may also show these entries when its configuration exposes guest logs."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if mayContainSensitiveValues {
                    Label(
                        "Arguments and return values can contain private application or user data.",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(4)
        }
    }

    private func loggingRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}
