import Foundation

struct BinaryPathScanner: Sendable {
    private static let maximumStringBytes = 16_384
    private static let maximumFindings = 256
    private static let overlapBytes = 256

    private static let markers = [
        "/var/jb",
        "/library/frameworks/cydiasubstrate.framework",
        "/library/mobilesubstrate",
        "/usr/lib/libsubstrate",
        "/usr/lib/libhooker",
        "cydiasubstrate",
        "mobilesubstrate",
        "ellekit",
        "preferenceloader",
        "/private/preboot/",
        "/opt/procursus/",
        "/var/containers/bundle/tweaksupport/",
    ]

    func scan(at url: URL) throws -> [ForbiddenPathFinding] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var findings: [ForbiddenPathFinding] = []
        var seen: Set<ForbiddenPathFindingKey> = []
        var buffer: [UInt8] = []
        buffer.reserveCapacity(256)

        func inspectBuffer() {
            guard buffer.count >= 4, findings.count < Self.maximumFindings else { return }
            let value = String(decoding: buffer, as: UTF8.self)
            let lowercase = value.lowercased()
            for marker in Self.markers where lowercase.contains(marker) {
                let key = ForbiddenPathFindingKey(marker: marker, value: value)
                if seen.insert(key).inserted {
                    findings.append(ForbiddenPathFinding(marker: marker, value: value))
                }
            }
        }

        for byte in data {
            if (0x20...0x7E).contains(byte) {
                buffer.append(byte)
                if buffer.count == Self.maximumStringBytes {
                    inspectBuffer()
                    buffer = Array(buffer.suffix(Self.overlapBytes))
                }
            } else {
                inspectBuffer()
                buffer.removeAll(keepingCapacity: true)
            }
            if findings.count == Self.maximumFindings { break }
        }
        inspectBuffer()
        return findings.sorted {
            ($0.marker, $0.value) < ($1.marker, $1.value)
        }
    }
}

private struct ForbiddenPathFindingKey: Hashable {
    let marker: String
    let value: String
}
