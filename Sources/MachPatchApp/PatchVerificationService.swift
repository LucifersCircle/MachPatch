import Foundation
import MachPatchCore
import MachPatchVerifier

protocol PatchVerificationServicing: Sendable {
    func verify(
        artifact: PatchBuildArtifact,
        targetInspection: MachOInspection
    ) throws -> DylibVerificationReport
}

struct PatchVerificationService: PatchVerificationServicing, Sendable {
    private let verifier: LiveContainerVerifier

    init(verifier: LiveContainerVerifier = LiveContainerVerifier()) {
        self.verifier = verifier
    }

    func verify(
        artifact: PatchBuildArtifact,
        targetInspection: MachOInspection
    ) throws -> DylibVerificationReport {
        try verifier.verify(
            dylibURL: artifact.dylibURL,
            targetInspection: targetInspection
        )
    }
}

struct PatchVerificationFailure: Equatable, Sendable {
    let message: String

    init(error: any Error) {
        message = error.localizedDescription
    }
}

enum PatchVerificationState: Equatable, Sendable {
    case idle
    case verifying
    case verified(DylibVerificationReport)
    case failed(PatchVerificationFailure)
    case unavailable(String)

    var isVerifying: Bool {
        if case .verifying = self { return true }
        return false
    }

    var report: DylibVerificationReport? {
        guard case .verified(let report) = self else { return nil }
        return report
    }
}
