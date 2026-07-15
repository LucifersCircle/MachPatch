import Foundation

public enum ObjectiveCAnalyzerError: Error, Equatable, LocalizedError, Sendable {
    case noSlices
    case sliceIndexOutOfRange(Int)
    case encryptedSlice(Int, UInt32)
    case allProvidersFailed([String])

    public var errorDescription: String? {
        switch self {
        case .noSlices:
            "The target does not contain a Mach-O slice."
        case .sliceIndexOutOfRange(let index):
            "Mach-O slice index \(index) does not exist."
        case .encryptedSlice(let index, let cryptID):
            "Mach-O slice \(index) is encrypted (cryptid \(cryptID)); Objective-C inspection is disabled."
        case .allProvidersFailed(let reasons):
            "No Objective-C metadata provider succeeded: \(reasons.joined(separator: "; "))"
        }
    }
}
