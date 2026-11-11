//
//  WallpaperStore.swift
//  PosterDrop
//
//  壁纸包的本地存储（Documents/Wallpapers）+ 索引持久化 + 文档目录自动发现。
//

import Foundation

final class WallpaperStore {

    static let shared = WallpaperStore()

    /// Documents/Wallpapers，同时开启 UIFileSharingEnabled，可直接用“文件”App 拖入。
    static let directory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static var indexURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("wallpapers.json")
    }

    private static let supportedExtensions: Set<String> = ["tendies", "zip", "posterboard", "wallpaper"]

    // MARK: - 索引

    func loadLibrary() -> [WallpaperItem] {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let items = try? JSONDecoder().decode([WallpaperItem].self, from: data) else {
            return []
        }
        // 丢掉已被删除的文件
        return items.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    func saveLibrary(_ items: [WallpaperItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }

    // MARK: - 导入

    func importWallpaper(from sourceURL: URL) async throws -> WallpaperItem {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let fileName = sourceURL.lastPathComponent
        guard !fileName.isEmpty else {
            throw AirliftError.failed("文件名为空，无法导入。")
        }

        let destination = Self.directory.appendingPathComponent(fileName)
        try await Self.copyFile(from: sourceURL, to: destination)

        let parsed = try await ArchiveInspector.inspect(archive: destination)

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        var item = WallpaperItem(
            name: (fileName as NSString).deletingPathExtension,
            fileName: fileName,
            kind: parsed.kind,
            descriptorCount: parsed.descriptorCount,
            isContainerArchive: parsed.isContainer,
            containsSQLiteStore: parsed.containsSQLite,
            fileSize: size,
            previewJPEG: parsed.previewJPEG,
            detectedExtensions: parsed.extensions
        )
        if item.name.isEmpty { item.name = "未命名壁纸" }
        return item
    }

    private static func copyFile(from source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    do {
                        try fileManager.copyItem(at: source, to: destination)
                    } catch {
                        // 安全作用域文件有时只能读数据，退化为内存拷贝
                        let data = try Data(contentsOf: source)
                        try data.write(to: destination, options: .atomic)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 删除

    func delete(_ item: WallpaperItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
    }

    // MARK: - 文档目录自动发现（AirDrop / 文件 App / 电脑导入）

    func discoverInDocuments() -> [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var found: [URL] = []

        let roots = [documents, Self.directory]
        for root in roots {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in contents {
                guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                if found.contains(where: { $0.lastPathComponent == url.lastPathComponent }) { continue }
                found.append(url)
            }
        }
        return found
    }
}
