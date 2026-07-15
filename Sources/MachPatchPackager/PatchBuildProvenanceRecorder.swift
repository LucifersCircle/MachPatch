import Foundation
import MachPatchBuilder
import MachPatchVerifier

public enum PatchBuildProvenanceRecorder {
    public static func record(
        verification report: DylibVerificationReport,
        in buildRecord: PatchBuildRecord
    ) throws -> PatchBuildRecord {
        let checks = report.checks
        let verification = PatchBuildVerificationRecord(
            outcome: report.isReadyForLiveContainerTesting
                ? .readyForLiveContainerTesting : .blocked,
            passedCheckCount: checks.count(where: { $0.status == .passed }),
            warningCheckCount: checks.count(where: { $0.status == .warning }),
            failedCheckCount: checks.count(where: { $0.status == .failed })
        )
        return try write(buildRecord.recordingVerification(verification))
    }

    public static func recordVerificationFailure(
        _ message: String,
        in buildRecord: PatchBuildRecord
    ) throws -> PatchBuildRecord {
        try write(
            buildRecord.recordingVerification(
                PatchBuildVerificationRecord(
                    outcome: .failedToVerify,
                    passedCheckCount: 0,
                    warningCheckCount: 0,
                    failedCheckCount: 0,
                    message: message
                )
            )
        )
    }

    private static func write(_ buildRecord: PatchBuildRecord) throws -> PatchBuildRecord {
        guard buildRecord.provenance != nil else {
            throw PatchBuildProvenanceError.missingContentHashes
        }
        try PatchBuildRecordCodec.write(
            buildRecord,
            to: URL(filePath: buildRecord.recordPath)
        )
        return buildRecord
    }
}

public enum PatchBuildProvenanceError: Error, Equatable, LocalizedError, Sendable {
    case missingContentHashes

    public var errorDescription: String? {
        switch self {
        case .missingContentHashes:
            "The build record has no content hashes, so its verification result cannot be recorded."
        }
    }
}
