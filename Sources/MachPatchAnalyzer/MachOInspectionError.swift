import Foundation

public enum MachOInspectionError: Error, Equatable, LocalizedError, Sendable {
    case unreadableFile(String)
    case invalidMachO(String)
    case malformedMachO(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let reason):
            "Mach-O file could not be read: \(reason)"
        case .invalidMachO(let reason):
            "Input is not a supported Mach-O file: \(reason)"
        case .malformedMachO(let reason):
            "Mach-O structure is malformed: \(reason)"
        }
    }
}
