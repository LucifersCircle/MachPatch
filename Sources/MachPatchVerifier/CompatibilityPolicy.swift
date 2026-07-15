import Foundation

enum CompatibilityPolicy {
    private static let forbiddenMarkers = [
        "/var/jb",
        "cydiasubstrate",
        "mobilesubstrate",
        "libsubstrate",
        "libhooker",
        "ellekit",
        "preferenceloader",
        "/private/preboot/",
        "/opt/procursus/",
        "tweaksupport",
    ]

    static func containsForbiddenMarker(_ value: String) -> Bool {
        let value = value.lowercased()
        return forbiddenMarkers.contains { value.contains($0) }
    }

    static func assessDependency(
        _ path: String,
        relativeTo outputDirectory: URL
    ) -> (classification: DependencyClassification, resolvedPath: String?) {
        if containsForbiddenMarker(path) {
            return (.forbiddenJailbreak, nil)
        }
        if path.hasPrefix("/System/Library/") || isAllowedSystemLibrary(path) {
            return (.appleSystem, nil)
        }

        let relativeName: String?
        if path.hasPrefix("@loader_path/") {
            relativeName = String(path.dropFirst("@loader_path/".count))
        } else if path.hasPrefix("@rpath/") {
            relativeName = String(path.dropFirst("@rpath/".count))
        } else {
            relativeName = nil
        }
        if let relativeName,
            let candidate = safeIncludedDependency(
                relativeName,
                outputDirectory: outputDirectory
            )
        {
            return (.includedAdjacent, candidate.path)
        }
        return (.unsupportedExternal, nil)
    }

    private static func isAllowedSystemLibrary(_ path: String) -> Bool {
        let allowedPrefixes = [
            "/usr/lib/libSystem.",
            "/usr/lib/libc++.",
            "/usr/lib/libcompression.",
            "/usr/lib/libobjc.",
            "/usr/lib/libsqlite3.",
            "/usr/lib/libxml2.",
            "/usr/lib/libz.",
            "/usr/lib/swift/",
        ]
        return allowedPrefixes.contains(where: path.hasPrefix)
    }

    private static func safeIncludedDependency(
        _ relativePath: String,
        outputDirectory: URL
    ) -> URL? {
        guard !relativePath.isEmpty,
            !relativePath.contains("\\"),
            !relativePath.contains("\0")
        else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }

        var candidate = outputDirectory
        for (index, component) in components.enumerated() {
            candidate.append(path: String(component))
            let values = try? candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values?.isSymbolicLink != true else { return nil }
            if index == components.count - 1 {
                guard values?.isRegularFile == true else { return nil }
            } else {
                guard values?.isDirectory == true else { return nil }
            }
        }
        return candidate
    }
}
