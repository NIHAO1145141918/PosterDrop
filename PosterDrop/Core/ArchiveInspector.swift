//
//  ArchiveInspector.swift
//  PosterDrop
//
//  .tendies / .zip 包的解析：不解压整包，只读中央目录判断结构，再单独取一张预览图。
//
//  PosterBoard 的存储布局：
//    <container>/Library/Application Support/PRBPosterExtensionDataStore/<61|59>/Extensions/<bundleID>/descriptors/<UUID>/
//  每个 descriptor 目录里通常包含：
//    versions/ , providerInfo.plist , Wallpaper.plist ,
//    com.apple.posterkit.provider.descriptor.identifier ,
//    com.apple.posterkit.provider.contents.userInfo , 以及 heic/mp4/plist 资源
//
//  另外也支持直接导入「已经解压好的文件夹」——很多人是从 Filza / 文件 App 里
//  把 descriptor 目录整个拷过来的，那种情况没有 zip 头。
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
    var entryCount: Int = 0
    var isDirectory: Bool = false
}

enum ArchiveInspector {

    /// descriptor 目录的判定特征（小写比较）
    private static let descriptorProbes: Set<String> = [
        "providerinfo.plist",
        "wallpaper.plist",
        "com.apple.posterkit.provider.descriptor.identifier",
        "com.apple.posterkit.provider.contents.userinfo",
        "versions"
    ]

    /// 这些目录名不可能是 descriptor 本身
    private static let ignoredDirectoryNames: Set<String> = [
        "container", "library", "application support", "prbposterextensiondatastore",
        "extensions", "descriptors", "ordered-descriptors", "mercury-descriptors",
        "mercurydescriptors", "video-descriptors", "videodescriptors", "versions"
    ]

    private static let imageExtensions: Set<String> = ["heic", "heif", "png", "jpg", "jpeg"]

    // MARK: - 入口

    static func inspect(archive: URL) async throws -> ParsedWallpaper {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ParsedWallpaper, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try inspectSync(archive: archive))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func inspectSync(archive: URL) throws -> ParsedWallpaper {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: archive.path, isDirectory: &isDirectory)
        guard exists else {
            throw AirliftError.failed("文件已被移动或删除：\(archive.lastPathComponent)")
        }
        if isDirectory.boolValue {
            return inspectDirectory(archive)
        }

        do {
            return try inspectZip(archive)
        } catch let zipError as ZipError {
            // 中央目录解析失败（少见格式 / 文件截断）：退回「整包解压后按目录判定」
            LogBus.shared.append("   · 原生解析失败：\(zipError.localizedDescription)，回退整包解压")
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("posterdrop-fallback-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            try extract(archive: archive, into: temp)
            var parsed = inspectDirectory(temp)
            parsed.isDirectory = false
            return parsed
        }
    }

    // MARK: - 文件夹

    private static func inspectDirectory(_ root: URL) -> ParsedWallpaper {
        var isContainer = false
        var containsSQLite = false

        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let item = enumerator.nextObject() as? URL {
                let lower = item.path.lowercased()
                if lower.contains("/container") { isContainer = true }
                if lower.contains("pbfposterextensiondatastoredatabasesqlite") || lower.hasSuffix(".sqlite3") {
                    containsSQLite = true
                }
                if lower.contains("__macosx") { enumerator.skipDescendants() }
            }
        }

        let fallback = isContainer ? "com.apple.WallpaperKit.CollectionsPoster" : PosterKind.collections.bundleID
        let folders = descriptorFolders(in: root)
        var extensions: [String] = []
        for folder in folders {
            let identifier = bundleIdentifier(for: folder, fallback: fallback)
            if !extensions.contains(identifier) { extensions.append(identifier) }
        }

        return ParsedWallpaper(
            kind: resolveKind(extensions: extensions, isContainer: isContainer),
            descriptorCount: max(folders.count, 1),
            isContainer: isContainer,
            containsSQLite: containsSQLite,
            previewJPEG: previewJPEG(in: root, maxPixel: 720, quality: 0.82),
            extensions: extensions,
            entryCount: folders.count,
            isDirectory: true
        )
    }

    // MARK: - zip

    private static func inspectZip(_ archive: URL) throws -> ParsedWallpaper {
        guard ZipArchive.looksLikeZip(archive) else {
            throw AirliftError.failed("「\(archive.lastPathComponent)」不是 zip / .tendies 包（文件头不是 PK）。\n如果它是文件夹形式的壁纸包，请用「导入文件夹」或在“文件”里长按文件夹导入。")
        }

        let zip = try ZipArchive(url: archive)
        let entries = zip.entries

        var isContainer = false
        var containsSQLite = false
        var directories = Set<String>()
        var marked = Set<String>()

        for entry in entries {
            let lower = entry.path.lowercased()
            if lower.contains("container/") { isContainer = true }
            if lower.contains("pbfposterextensiondatastoredatabasesqlite") || lower.hasSuffix(".sqlite3") {
                containsSQLite = true
            }

            // 收集所有目录
            let components = entry.path.split(separator: "/").map(String.init)
            if !components.isEmpty {
                var current = ""
                let directoryComponents = entry.isDirectory ? components : Array(components.dropLast())
                for component in directoryComponents {
                    current += (current.isEmpty ? "" : "/") + component
                    directories.insert(current)
                }
            }

            if entry.isDirectory { continue }
            if descriptorProbes.contains(entry.lastComponent.lowercased()) {
                marked.insert(entry.directoryPath)
            }
        }

        // versions/ 目录的父目录也是 descriptor
        for directory in directories where (directory as NSString).lastPathComponent.lowercased() == "versions" {
            marked.insert((directory as NSString).deletingLastPathComponent)
        }

        let descriptorPaths = outermost(marked)

        let fallback = isContainer ? "com.apple.WallpaperKit.CollectionsPoster" : PosterKind.collections.bundleID
        var extensions: [String] = []
        for path in descriptorPaths {
            let identifier = bundleIdentifier(forZipPath: path, fallback: fallback)
            if !extensions.contains(identifier) { extensions.append(identifier) }
        }

        return ParsedWallpaper(
            kind: resolveKind(extensions: extensions, isContainer: isContainer),
            descriptorCount: max(descriptorPaths.count, 1),
            isContainer: isContainer,
            containsSQLite: containsSQLite,
            previewJPEG: previewJPEG(in: zip, maxPixel: 720, quality: 0.82),
            extensions: extensions,
            entryCount: entries.count,
            isDirectory: false
        )
    }

    /// 去掉嵌套的 descriptor 目录（保留最外层）。
    private static func outermost(_ paths: Set<String>) -> [String] {
        let sorted = paths
            .filter { !$0.isEmpty }
            .sorted { $0.count < $1.count }

        var kept: [String] = []
        for path in sorted {
            let isNested = kept.contains { path.hasPrefix($0 + "/") }
            if !isNested { kept.append(path) }
        }
        return kept
    }

    // MARK: - 解压（注入时用）

    /// 把包解到指定目录。文件夹直接拷贝，zip 先走原生实现，失败再回退 Rust。
    static func extract(archive: URL, into directory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: archive.path, isDirectory: &isDirectory) else {
            throw AirliftError.failed("文件不存在：\(archive.lastPathComponent)")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if isDirectory.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? []
            for item in items {
                let source = archive.appendingPathComponent(item)
                let target = directory.appendingPathComponent(item)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
            return
        }

        do {
            let zip = try ZipArchive(url: archive)
            let count = try zip.extractAll(to: directory)
            guard count > 0 else {
                throw ZipError.corrupt("解压后没有任何文件")
            }
            LogBus.shared.append("   · 原生解压完成（\(count) 个文件）")
            return
        } catch {
            LogBus.shared.append("   · 原生解压失败：\(error.localizedDescription)，改用 Airlift 解压")
        }

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

    // MARK: - descriptor 发现（文件系统）

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
        if ignoredDirectoryNames.contains(name) { return false }

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
        let components = folder.path.split(separator: "/").map(String.init)
        if let identifier = structuralIdentifier(in: components) {
            return identifier
        }

        // suggestionMetadata.plist 里的 $objects 字符串
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

        // descriptor 标识内容（v6x.colorA 之类的符号 → Mercury）
        let identifierURL = folder.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
        if let identifier = try? String(contentsOf: identifierURL, encoding: .utf8) {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("v6") || trimmed.hasPrefix("v5") || trimmed.hasPrefix("v4") || trimmed.contains(".color") {
                return "com.apple.MercuryPoster"
            }
        }

        if let identifier = keywordIdentifier(in: folder.path.lowercased()) {
            return identifier
        }

        return fallback
    }

    /// 纯字符串版本：入参可以是 zip 里的路径。
    static func bundleIdentifier(forZipPath path: String, fallback: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        if let identifier = structuralIdentifier(in: components) {
            return identifier
        }
        if let identifier = keywordIdentifier(in: path.lowercased()) {
            return identifier
        }
        return fallback
    }

    private static func structuralIdentifier(in components: [String]) -> String? {
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
        return nil
    }

    private static func keywordIdentifier(in lowerPath: String) -> String? {
        if lowerPath.contains("mercury") { return "com.apple.MercuryPoster" }
        if lowerPath.contains("kaleidoscope") { return "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster" }
        if lowerPath.contains("unity") { return "com.apple.Posters.UnityPosterApp.UnityPosterExtension" }
        if lowerPath.contains("collection") || lowerPath.contains("wallpaperkit") {
            return "com.apple.WallpaperKit.CollectionsPoster"
        }
        if lowerPath.contains("/video") || lowerPath.contains("/photo") {
            return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        }
        return nil
    }

    // MARK: - 预览图（文件系统）

    static func previewJPEG(in root: URL, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (url: URL, score: Int)?
        while let item = enumerator.nextObject() as? URL {
            let lower = item.path.lowercased()
            if lower.contains("__macosx") { continue }
            guard imageExtensions.contains(item.pathExtension.lowercased()) else { continue }
            let score = previewScore(for: lower)
            if best == nil || score > best!.score {
                best = (item, score)
            }
        }

        guard let bestURL = best?.url else { return nil }
        if let data = thumbnailJPEG(url: bestURL, maxPixel: maxPixel, quality: quality) {
            return data
        }
        if let image = UIImage(contentsOfFile: bestURL.path) {
            return resizedJPEG(image: image, maxPixel: maxPixel, quality: quality)
        }
        return nil
    }

    // MARK: - 预览图（zip，只解一张）

    static func previewJPEG(in zip: ZipArchive, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        var best: (entry: ZipEntry, score: Int)?
        for entry in zip.entries {
            guard !entry.isDirectory else { continue }
            let lower = entry.path.lowercased()
            if lower.contains("__macosx") { continue }
            guard imageExtensions.contains(entry.nameExtension) else { continue }
            let score = previewScore(for: lower)
            if best == nil || score > best!.score {
                best = (entry, score)
            }
        }

        guard let entry = best?.entry else { return nil }
        // 预览图一般不大会超过 32 MB，超出就放弃，别为了一张图卡住导入
        guard let data = try? zip.data(for: entry, limit: 32 * 1024 * 1024) else {
            LogBus.shared.append("   · 预览图跳过（\(entry.lastComponent) 解压失败）")
            return nil
        }
        return thumbnailJPEG(data: data, maxPixel: maxPixel, quality: quality)
    }

    private static func previewScore(for lowerPath: String) -> Int {
        var score = 10
        if lowerPath.contains("proxy") || lowerPath.contains("adjusted") {
            score += 90
        } else if lowerPath.contains("background") || lowerPath.contains("settling") {
            score += 70
        } else if lowerPath.contains("preview") || lowerPath.contains("thumb") {
            score += 50
        } else if lowerPath.contains("asset.resource") {
            score += 40
        }
        if lowerPath.hasSuffix(".png") || lowerPath.hasSuffix(".jpg") || lowerPath.hasSuffix(".jpeg") {
            score += 4
        }
        return score
    }

    static func thumbnailJPEG(data: Data, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)?.jpegData(compressionQuality: quality)
        }
        return thumbnailJPEG(source: source, maxPixel: maxPixel, quality: quality)
    }

    static func thumbnailJPEG(url: URL, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return thumbnailJPEG(source: source, maxPixel: maxPixel, quality: quality)
    }

    private static func thumbnailJPEG(source: CGImageSource, maxPixel: CGFloat, quality: CGFloat) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
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
