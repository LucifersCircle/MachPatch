import Foundation

public enum HumanVerificationReportFormatter {
    public static func render(_ report: DylibVerificationReport) -> String {
        var lines = [
            "LiveContainer compatibility",
            "",
            "Dylib",
            "  \(report.dylibPath)",
            "",
        ]

        appendSection(
            title: "Architecture",
            codes: [.fileType, .architecture, .lipoAgreement],
            report: report,
            lines: &lines
        )
        appendSection(
            title: "Platform and deployment",
            codes: [.platform, .deploymentTarget],
            report: report,
            lines: &lines
        )
        appendSection(
            title: "Install name",
            codes: [.installName],
            report: report,
            lines: &lines
        )
        appendSection(
            title: "Dependencies and symbols",
            codes: [.dependency, .unresolvedSymbols],
            report: report,
            lines: &lines
        )
        appendSection(
            title: "Forbidden jailbreak paths",
            codes: [.forbiddenFilesystemPath],
            report: report,
            lines: &lines
        )
        appendSection(
            title: "Target compatibility",
            codes: [.targetCompatibility],
            report: report,
            lines: &lines
        )

        lines.append("Result")
        if report.isReadyForLiveContainerTesting {
            lines.append("  Ready for LiveContainer testing")
        } else {
            let count = report.blockingFailures.count
            lines.append("  Blocked by \(count) verification failure\(count == 1 ? "" : "s")")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func appendSection(
        title: String,
        codes: Set<VerificationCheckCode>,
        report: DylibVerificationReport,
        lines: inout [String]
    ) {
        lines.append(title)
        for check in report.checks where codes.contains(check.code) {
            lines.append("  \(symbol(for: check.status)) \(check.message)")
            for evidence in check.evidence {
                lines.append("      \(evidence)")
            }
        }
        lines.append("")
    }

    private static func symbol(for status: VerificationCheckStatus) -> String {
        switch status {
        case .passed: "PASS"
        case .warning: "WARN"
        case .failed: "FAIL"
        }
    }
}
