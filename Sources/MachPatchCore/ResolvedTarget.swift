import Foundation

/// The kind of user input from which a target executable was resolved.
public enum InputKind: String, Codable, Sendable {
    case ipa
    case applicationBundle = "app"
    case machO
}

/// Stable, serializable information about an input's primary executable.
public struct ResolvedTarget: Codable, Equatable, Sendable {
    public let sourceType: InputKind
    public let sourcePath: String
    public let bundlePath: String?
    public let bundleIdentifier: String?
    public let displayName: String?
    public let minimumOSVersion: String?
    public let supportedPlatforms: [String]
    public let executableName: String
    public let executablePath: String
    public let sha256: String

    public init(
        sourceType: InputKind,
        sourcePath: String,
        bundlePath: String?,
        bundleIdentifier: String?,
        displayName: String?,
        minimumOSVersion: String?,
        supportedPlatforms: [String],
        executableName: String,
        executablePath: String,
        sha256: String
    ) {
        self.sourceType = sourceType
        self.sourcePath = sourcePath
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.minimumOSVersion = minimumOSVersion
        self.supportedPlatforms = supportedPlatforms
        self.executableName = executableName
        self.executablePath = executablePath
        self.sha256 = sha256
    }

    public var executableURL: URL {
        URL(filePath: executablePath)
    }
}
