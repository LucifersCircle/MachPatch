import Foundation

public enum InputResolutionError: Error, Equatable, LocalizedError, Sendable {
    case pathDoesNotExist(String)
    case unsupportedInput(String)
    case inputIsSymbolicLink(String)
    case missingPayload
    case missingApplication
    case multipleApplications([String])
    case invalidApplicationBundle(String)
    case missingInfoPlist(String)
    case unreadableInfoPlist(String)
    case missingBundleExecutable(String)
    case unsafeExecutableName(String)
    case executableNotFound(String)
    case executableIsSymbolicLink(String)
    case executableIsNotMachO(String)
    case unsafeArchive(String)
    case archiveExtractionFailed(String)
    case hashingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pathDoesNotExist(let path):
            "Input does not exist: \(path)"
        case .unsupportedInput(let path):
            "Unsupported input. Expected an IPA, .app directory, or Mach-O executable: \(path)"
        case .inputIsSymbolicLink(let path):
            "Symbolic-link inputs are not accepted: \(path)"
        case .missingPayload:
            "The IPA does not contain a Payload directory."
        case .missingApplication:
            "The IPA Payload directory does not contain an application bundle."
        case .multipleApplications(let names):
            "The IPA contains multiple applications; selection is required: \(names.joined(separator: ", "))"
        case .invalidApplicationBundle(let path):
            "The application bundle is invalid: \(path)"
        case .missingInfoPlist(let path):
            "The application bundle does not contain Info.plist: \(path)"
        case .unreadableInfoPlist(let reason):
            "Info.plist could not be read: \(reason)"
        case .missingBundleExecutable(let path):
            "Info.plist does not contain a non-empty CFBundleExecutable: \(path)"
        case .unsafeExecutableName(let name):
            "CFBundleExecutable is not a safe file name: \(name)"
        case .executableNotFound(let path):
            "The bundle executable does not exist or is not a regular file: \(path)"
        case .executableIsSymbolicLink(let path):
            "The bundle executable must not be a symbolic link: \(path)"
        case .executableIsNotMachO(let path):
            "The resolved executable is not a recognized Mach-O file: \(path)"
        case .unsafeArchive(let reason):
            "The IPA archive is unsafe or unsupported: \(reason)"
        case .archiveExtractionFailed(let reason):
            "The IPA could not be extracted: \(reason)"
        case .hashingFailed(let reason):
            "The executable SHA-256 could not be calculated: \(reason)"
        }
    }
}
