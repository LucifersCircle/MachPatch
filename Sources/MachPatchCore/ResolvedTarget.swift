import Foundation

/// The kind of user input from which a target executable was resolved.
public enum InputKind: String, Codable, Sendable {
    case ipa
    case applicationBundle = "app"
    case frameworkBundle = "framework"
    case machO
}

/// The relationship between a Mach-O image and the input that contains it.
public enum ResolvedImageKind: String, Codable, Equatable, Sendable {
    case mainExecutable
    case dynamicFramework
    case appExtension
    case standaloneFramework
    case standaloneMachO
}

/// A single inspectable Mach-O image discovered in an input target.
public struct ResolvedImage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ResolvedImageKind
    public let relativePath: String
    public let bundlePath: String?
    public let bundleIdentifier: String?
    public let displayName: String?
    public let minimumOSVersion: String?
    public let supportedPlatforms: [String]
    public let executableName: String
    public let executablePath: String
    public let sha256: String

    public init(
        id: String,
        kind: ResolvedImageKind,
        relativePath: String,
        bundlePath: String?,
        bundleIdentifier: String?,
        displayName: String?,
        minimumOSVersion: String?,
        supportedPlatforms: [String],
        executableName: String,
        executablePath: String,
        sha256: String
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
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

    public var hasBundleMetadata: Bool {
        bundlePath != nil
    }
}

/// A malformed embedded image candidate that was not safe to inspect.
public struct ResolvedImageDiscoveryIssue: Codable, Equatable, Sendable {
    public let kind: ResolvedImageKind
    public let relativeBundlePath: String
    public let message: String

    public init(
        kind: ResolvedImageKind,
        relativeBundlePath: String,
        message: String
    ) {
        self.kind = kind
        self.relativeBundlePath = relativeBundlePath
        self.message = message
    }
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
    public let images: [ResolvedImage]
    public let imageDiscoveryIssues: [ResolvedImageDiscoveryIssue]

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
        sha256: String,
        images: [ResolvedImage]? = nil,
        imageDiscoveryIssues: [ResolvedImageDiscoveryIssue] = []
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
        let defaultImage = ResolvedImage(
            id: Self.defaultImageID(
                sourceType: sourceType,
                executableName: executableName
            ),
            kind: Self.defaultImageKind(for: sourceType),
            relativePath: executableName,
            bundlePath: bundlePath,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            minimumOSVersion: minimumOSVersion,
            supportedPlatforms: supportedPlatforms,
            executableName: executableName,
            executablePath: executablePath,
            sha256: sha256
        )
        if let images, !images.isEmpty {
            self.images = images
        } else {
            self.images = [defaultImage]
        }
        self.imageDiscoveryIssues = imageDiscoveryIssues
    }

    public var executableURL: URL {
        URL(filePath: executablePath)
    }

    public var primaryImage: ResolvedImage {
        images[0]
    }

    private static func defaultImageKind(for sourceType: InputKind) -> ResolvedImageKind {
        switch sourceType {
        case .ipa, .applicationBundle:
            .mainExecutable
        case .frameworkBundle:
            .standaloneFramework
        case .machO:
            .standaloneMachO
        }
    }

    private static func defaultImageID(
        sourceType: InputKind,
        executableName: String
    ) -> String {
        "\(defaultImageKind(for: sourceType).rawValue):\(executableName)"
    }
}
