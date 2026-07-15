import AppKit
import Foundation
import ImageIO
import MachPatchCore
import SwiftUI

struct TargetIconLoader {
    private static let maximumIconBytes = 16 * 1_024 * 1_024

    func loadIconData(for target: ResolvedTarget) -> Data? {
        guard let bundlePath = target.bundlePath else { return nil }
        let bundleURL = URL(filePath: bundlePath, directoryHint: .isDirectory)
        let infoURL = bundleURL.appending(path: "Info.plist")

        guard let infoData = try? Data(contentsOf: infoURL),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil
            ),
            let info = propertyList as? [String: Any]
        else { return nil }

        let declaredNames = declaredIconNames(in: info)
        guard !declaredNames.isEmpty,
            let bundleContents = try? FileManager.default.contentsOfDirectory(
                at: bundleURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        else { return nil }

        let candidates = bundleContents.compactMap { url -> IconCandidate? in
            guard Self.isSupportedImage(url), matches(url: url, declarations: declaredNames),
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let fileSize = values.fileSize,
                fileSize > 0,
                fileSize <= Self.maximumIconBytes,
                let data = try? Data(contentsOf: url),
                let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }

            let properties =
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            return IconCandidate(data: data, pixelCount: width * height)
        }

        return candidates.max {
            ($0.pixelCount, $0.data.count) < ($1.pixelCount, $1.data.count)
        }?.data
    }

    private func declaredIconNames(in info: [String: Any]) -> [String] {
        var names: [String] = []
        appendIconNames(from: info["CFBundleIcons"], to: &names)
        appendIconNames(from: info["CFBundleIcons~ipad"], to: &names)
        if let rootNames = info["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: rootNames)
        }
        if let rootName = info["CFBundleIconFile"] as? String {
            names.append(rootName)
        }

        var seen: Set<String> = []
        return names.compactMap { name in
            let safeName = URL(filePath: name).lastPathComponent
            guard safeName == name, !safeName.isEmpty, seen.insert(safeName).inserted else {
                return nil
            }
            return safeName
        }
    }

    private func appendIconNames(from value: Any?, to names: inout [String]) {
        guard let icons = value as? [String: Any],
            let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any]
        else { return }
        if let files = primaryIcon["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        if let name = primaryIcon["CFBundleIconName"] as? String {
            names.append(name)
        }
    }

    private func matches(url: URL, declarations: [String]) -> Bool {
        let actualName = url.lastPathComponent
        let actualStem = url.deletingPathExtension().lastPathComponent
        return declarations.contains { declaration in
            if declaration.contains(".") && actualName == declaration {
                return true
            }
            let declaredStem = URL(filePath: declaration).deletingPathExtension().lastPathComponent
            return actualStem == declaredStem || actualStem.hasPrefix("\(declaredStem)@")
                || actualStem.hasPrefix("\(declaredStem)~")
        }
    }

    private static func isSupportedImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }
}

private struct IconCandidate {
    let data: Data
    let pixelCount: Int
}

struct TargetIconView: View {
    let iconData: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.58, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.tint.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var image: NSImage? {
        iconData.flatMap(NSImage.init(data:))
    }
}
