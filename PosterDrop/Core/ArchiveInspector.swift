//
//  ArchiveInspector.swift
//  PosterDrop
//
//  .tendies / .zip 包的解析：解压 → 找 descriptor 目录 → 判定壁纸类型 → 抽取预览图。
//
//  PosterBoard 的存储布局：
//    <container>/Library/Application Support/PRBPosterExtensionDataStore/<61|59>/Extensions/<bundleID>/descriptors/<UUID>/
//  每个 descriptor 目录里通常包含：
//    versions/ , providerInfo.plist , Wallpaper.plist ,
//    com.apple.posterkit.provider.descriptor.identifier ,
//    com.apple.posterkit.provider.contents.userInfo , 以及 heic/mp4/plist 资源
//

import Foundation
import UIKit
import ImageIO

struct ParsedWallpaper {
    var kind: PosterKind
    var descriptorCount: Int
    var isContainer: Bool
    var containsSQLite: Bool
    var previewJPEG: Data?
    var extensions: [String]
}

enum ArchiveInspector {

    // MARK: - 入口

    static func inspect(archive: URL) async throws -> ParsedWallpaper {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ParsedWallpaper, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let parsed = try inspectSync(archive: archive)
                    continuation.resume(returning: parsed)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func inspectSync(archive: URL) throws -> ParsedWallpaper {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterdrop-inspect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try extract(archive: archive, into: tempRoot)

        var isContainer = false
        var containsSQLite = false

        if let enumerator = FileManager.default.enumerator(
            at: tempRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let item = enumerator.nextObject() as? URL {
                let lower = item.path.lowercased()
                if lower.contains("/container") {
                    isContainer = true
                }
                if lower.contains("pbfposterextensiondatastoredatabasesqlite") || lower.hasSuffix(".sqlite3") {
                    containsSQLite = true
                }
                if lower.contains("__macosx") {
                    enumerator.skipDescendants()
                }
            }
        }

        let fallback = isContainer ? "com.apple.WallpaperKit.CollectionsPoster" : PosterKind.collections.bundleID
        let folders = descriptorFolders(in: tempRoot)
        var extensions: [String] = []
        for folder in folders {
            let identifier = bundleIdentifier(for: folder, fallback: fallback)
            if !extensions.contains(identifier) {
                extensions.append(identifier)
            }
        }

        let kind = resolveKind(extensions: extensions, isContainer: isContainer)
        let preview = previewJPEG(in: tempRoot, maxPixel: 720, quality: 0.82)

        return ParsedWallpaper(
            kind: kind,
            descriptorCount: max(folders.count, 1),
            isContainer: isContainer,
            containsSQLite: containsSQLite,
            previewJPEG: preview,
            extensions: extensions
        )
    }

    // MARK: - 解压

    static func extract(archive: URL, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rc = Airlift.extractZip(archive: archive.path, into: directory.path)
        guard rc == 0 else {
            throw AirliftError.failed("无法解压 \(archive.lastPathComponent)（错误码 \(rc)）：文件可能不是 zip/tendies 格式，或已被截断。")
        }
    }

    // MARK: - 类型判定

    static func resolveKind(extensions: [String], isContainer: Bool) -> PosterKind {
        if extensions.contains(where: { $0.contains("MercuryPoster") }) { return .mercury }
        if extensions.contains(where: { $0.contains("PhotosPosterProvider") }) { return .photos }
        if extensions.contains(where: { $0.contains("Kaleidoscope") }) { return .kaleidoscope }
        if extensions.contains(where: { $0.contains("UnityPoster") }) { return .unity }
        if extensions.contains(where: { $0.contains("CollectionsPoster") }) { return .collections }
        if isContainer { return .collections }
        return .generic
    }

    // MARK: - descriptor 发现

    static func descriptorFolders(in root: URL) -> [URL] {
        if isDescriptorFolder(root) {
            return [root]
        }

        var results: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let item = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let name = item.lastPathComponent
            if name.hasPrefix(".") || name.uppercased() == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }

            if isDescriptorFolder(item) {
                results.append(item)
                enumerator.skipDescendants()
            }
        }
        return results
    }

    static func isDescriptorFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }

        let name = url.lastPathComponent.lowercased()
        if name == "__macosx" || name.hasPrefix(".") { return false }

        let ignored: Set<String> = [
            "container", "library", "application support", "prbposterextensiondatastore",
            "extensions", "descriptors", "ordered-descriptors", "mercury-descriptors",
            "mercurydescriptors", "video-descriptors", "videodescriptors"
        ]
        if ignored.contains(name) { return false }

        let probes = [
            "versions",
            "providerInfo.plist",
            "com.apple.posterkit.provider.descriptor.identifier",
            "Wallpaper.plist",
            "com.apple.posterkit.provider.contents.userInfo"
        ]
        for probe in probes {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(probe).path) {
                return true
            }
        }
        return url.pathExtension.lowercased() == "wallpaper"
    }

    /// 从路径 / 元数据 / 标识文件推断该 descriptor 属于哪个扩展。
    static func bundleIdentifier(for folder: URL, fallback: String) -> String {
        // 1) .../Extensions/<bundleID>/descriptors/<desc>
        let components = folder.pathComponents
        for index in 0..<components.count {
            if components[index].lowercased() == "extensions", index + 1 < components.count {
                let candidate = components[index + 1]
                if candidate.contains(".") { return candidate }
            }
            if components[index].lowercased() == "descriptors", index > 0 {
                let candidate = components[index - 1]
                if candidate.contains("."), !candidate.lowercased().contains("store") {
                    return candidate
                }
            }
        }

        // 2) suggestionMetadata.plist 里的 $objects 字符串
        let metadataURL = folder.appendingPathComponent("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")
        if let data = try? Data(contentsOf: metadataURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let objects = plist["$objects"] as? [Any] {
            for object in objects {
                if let string = object as? String, string.hasPrefix("com.apple."), string.contains("Poster") {
                    return string
                }
            }
        }

        // 3) descriptor 标识内容（v6x.colorA 之类的符号 → Mercury）
        let identifierURL = folder.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
        if let identifier = try? String(contentsOf: identifierURL, encoding: .utf8) {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("v6") || trimmed.hasPrefix("v5") || trimmed.hasPrefix("v4") || trimmed.contains(".color") {
                return "com.apple.MercuryPoster"
            }
        }

        // 4) 路径关键字
        let lower = folder.path.lowercased()
        if lower.contains("mercury") { return "com.apple.MercuryPoster" }
        if lower.contains("video") || lower.contains("photo") { return "com.apple.PhotosUIPrivate.PhotosPosterProvider" }
        if lower.contains("collection") || lower.contains("wallpaperkit") { return "com.apple.WallpaperKit.CollectionsPoster" }
        if lower.contains("kaleidoscope") { return "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster" }
        if lower.contains("unity") { return "com.apple.Posters.UnityPosterApp.UnityPosterExtension" }

        return fallback
    }

    // MARK: - 预览图

    static func previewJPEG(in root: URL, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (url: URL, score: Int)?
        let supportedExtensions: Set<String> = ["heic", "png", "jpg", "jpeg"]

        while let item = enumerator.nextObject() as? URL {
            let fileExtension = item.pathExtension.lowercased()
            guard supportedExtensions.contains(fileExtension) else { continue }
            let lower = item.path.lowercased()
            if lower.contains("__macosx") { continue }

            var score = 10
            if lower.contains("proxy") || lower.contains("adjusted") {
                score += 90
            } else if lower.contains("background") || lower.contains("settling") {
                score += 70
            } else if lower.contains("preview") || lower.contains("thumb") {
                score += 50
            } else if lower.contains("asset.resource") {
                score += 40
            }

            if best == nil || score > best!.score {
                best = (item, score)
            }
        }

        guard let bestURL = best?.url else { return nil }
        if let data = thumbnailJPEG(url: bestURL, maxPixel: maxPixel, quality: quality) {
            return data
        }

        // 退化路径：直接读取
        if let image = UIImage(contentsOfFile: bestURL.path) {
            return resizedJPEG(image: image, maxPixel: maxPixel, quality: quality)
        }
        return nil
    }

    static func thumbnailJPEG(url: URL, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    static func resizedJPEG(image: UIImage, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxPixel / max(size.width, size.height))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
