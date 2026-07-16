import Foundation
import MachPatchCore

public struct ObjectiveCAnalyzer: Sendable {
    private let providers: [any ObjectiveCMetadataProvider]

    public init() {
        providers = [
            LIEFObjectiveCMetadataProvider(),
            OtoolObjectiveCMetadataProvider(),
        ]
    }

    init(providers: [any ObjectiveCMetadataProvider]) {
        self.providers = providers
    }

    public func analyze(
        _ target: ResolvedTarget,
        sliceIndex: Int = 0
    ) throws -> ObjectiveCAnalysis {
        try analyze(target, image: target.primaryImage, sliceIndex: sliceIndex)
    }

    public func analyze(
        _ target: ResolvedTarget,
        image: ResolvedImage,
        sliceIndex: Int = 0
    ) throws -> ObjectiveCAnalysis {
        let slices = try MachOInspector().inspect(at: image.executableURL)
        guard !slices.isEmpty else { throw ObjectiveCAnalyzerError.noSlices }
        guard slices.indices.contains(sliceIndex) else {
            throw ObjectiveCAnalyzerError.sliceIndexOutOfRange(sliceIndex)
        }

        let slice = slices[sliceIndex]
        if slice.encrypted {
            throw ObjectiveCAnalyzerError.encryptedSlice(
                sliceIndex,
                slice.encryptionCryptID ?? 0
            )
        }

        var notices: [String] = []
        var warnings: [String] = []
        var failureReasons: [String] = []
        for provider in providers {
            switch provider.availability() {
            case .unavailable(let reason):
                let failureReason = "\(provider.backend.rawValue) unavailable: \(reason)"
                failureReasons.append(failureReason)
                notices.append(
                    "Optional \(provider.backend.rawValue) backend unavailable: \(reason)"
                )
                continue
            case .available:
                break
            }

            do {
                let rawMetadata = try provider.extractMetadata(
                    from: image.executableURL,
                    slice: slice
                )
                return ObjectiveCAnalysis(
                    target: target,
                    image: image,
                    sliceIndex: sliceIndex,
                    architecture: slice.architecture,
                    backend: provider.backend,
                    notices: notices,
                    warnings: warnings,
                    metadata: ObjectiveCMetadataNormalizer.normalize(
                        rawMetadata,
                        imageName: image.executableName
                    )
                )
            } catch {
                let failureReason =
                    "\(provider.backend.rawValue) failed: \(error.localizedDescription)"
                failureReasons.append(failureReason)
                warnings.append(failureReason)
            }
        }

        throw ObjectiveCAnalyzerError.allProvidersFailed(failureReasons)
    }
}
