import Foundation
import MachPatchAnalyzer
import MachPatchBuilder

protocol TargetLoading: Sendable {
    func loadTarget(at inputURL: URL) async throws -> LoadedTarget
}

struct TargetLoader: TargetLoading {
    func loadTarget(at inputURL: URL) async throws -> LoadedTarget {
        try await Task.detached(priority: .userInitiated) {
            let hasSecurityScope = inputURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    inputURL.stopAccessingSecurityScopedResource()
                }
            }

            try Task.checkCancellation()
            return try InputResolver().withResolvedTarget(at: inputURL) { target in
                try Task.checkCancellation()
                let inspection = try MachOInspector().inspect(target)
                return LoadedTarget(
                    inputURL: inputURL,
                    target: target,
                    inspection: inspection,
                    architectureReport: ArchitectureResolver.report(for: inspection.slices)
                )
            }
        }.value
    }
}
