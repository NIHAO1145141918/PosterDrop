//
//  WallpaperStore.swift
//  PosterDrop
//
//  壁纸包的本地存储（Documents/Wallpapers）+ 索引持久化 + 文档目录自动发现。
//
//  导入是整条链路上最容易出问题的一步，这里做了几件事兜住：
//  - iCloud 占位文件：先触发下载，再用 NSFileCoordinator 协调读取；
//  - 安全作用域：文件 App 选进来的 URL 必须 startAccessingSecurityScopedResource；
//  - 原子拷贝：先写到临时名，成功后再挪到最终位置，失败不会留下半个文件；
//  - 文件名冲突：自动加「(2)」，不覆盖已有壁纸；
//  - 文件夹形式的壁纸包：直接整目录拷进来，不需要 zip。
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

    static var documentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var indexURL: URL {
        return documentsDirectory.appendingPathComponent("wallpapers.json")
    }

    /// 认识的扩展名（大小写不敏感）
    static let supportedExtensions: Set<String> = [
        "tendies", "zip", "posterboard", "wallpaper", "archive"
    ]

    /// 扫描结果，便于在界面上说清“扫了几个、命中几个”。
    struct ScanResult {
        var candidates: [URL] = []
        var scannedFiles: Int = 0
        var scannedFolders: Int = 0
    }

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

    func importWallpaper(from sourceURL: URL, log: @escaping (String) -> Void = { LogBus.shared.append($0) }) async throws -> WallpaperItem {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WallpaperItem, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let item = try self.importSync(from: sourceURL, log: log)
                    continuation.resume(returning: item)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func importSync(from sourceURL: URL, log: (String) -> Void) throws -> WallpaperItem {
        let manager = FileManager.default
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        log("📥 导入 \(sourceURL.lastPathComponent)")

        let source = try resolveSource(sourceURL, log: log)

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw AirliftError.failed("文件不存在：\(source.lastPathComponent)")
        }
        guard manager.isReadableFile(atPath: source.path) else {
            throw AirliftError.failed("没有读取「\(source.lastPathComponent)」的权限。请先在“文件”App 里把它下载到本机（长按 › 下载），再导入。")
        }

        var fileName = source.lastPathComponent
        if fileName.isEmpty {
            fileName = "壁纸包-\(Int(Date().timeIntervalSince1970)).tendies"
        }

        let destination = Self.uniqueDestination(for: fileName)
        try copyAtomically(from: source, to: destination, isDirectory: isDirectory.boolValue, log: log)

        let parsed: ParsedWallpaper
        do {
            parsed = try ArchiveInspector.inspectSync(archive: destination)
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }

        let size = Self.sizeOfItem(at: destination)
        log("   · \(parsed.kind.title)，\(parsed.descriptorCount) 个描述符，\(parsed.isDirectory ? "文件夹" : "\(parsed.entryCount) 个条目")")

        var item = WallpaperItem(
            name: (fileName as NSString).deletingPathExtension,
            fileName: destination.lastPathComponent,
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

    /// iCloud 占位文件先拉下来；其它情况原样返回。
    private func resolveSource(_ url: URL, log: (String) -> Void) throws -> URL {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
            return url
        }
        if values.ubiquitousItemDownloadingStatus == .current {
            return url
        }

        log("   · iCloud 文件尚未下载，正在拉取…")
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let status = try? url.resourceValues(forKeys: keys).ubiquitousItemDownloadingStatus,
               status == .current {
                log("   · 已下载到本机")
                return url
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        log("   · 等待下载超时，直接尝试读取")
        return url
    }

    private func copyAtomically(from source: URL, to destination: URL, isDirectory: Bool, log: (String) -> Void) throws {
        let manager = FileManager.default
        try? manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: isDirectory)
        try? manager.removeItem(at: temporary)

        var coordinatedError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinatedError) { readableURL in
            do {
                try manager.copyItem(at: readableURL, to: temporary)
            } catch {
                copyError = error
            }
        }

        if let copyError {
            // 协调读取失败（或这个 URL 不支持协调）时，直接按字节读一次
            log("   · 协调读取失败（\(copyError.localizedDescription)），改用直接读取")
            try? manager.removeItem(at: temporary)
            do {
                if isDirectory {
                    try manager.copyItem(at: source, to: temporary)
                } else {
                    let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                    try data.write(to: temporary, options: .atomic)
                }
            } catch {
                try? manager.removeItem(at: temporary)
                let reason = coordinatedError?.localizedDescription ?? error.localizedDescription
                throw AirliftError.failed("拷贝「\(source.lastPathComponent)」失败：\(reason)")
            }
        } else if let coordinatedError {
            try? manager.removeItem(at: temporary)
            throw AirliftError.failed("读取「\(source.lastPathComponent)」失败：\(coordinatedError.localizedDescription)")
        }

        guard manager.fileExists(atPath: temporary.path) else {
            throw AirliftError.failed("拷贝「\(source.lastPathComponent)」后文件不见了，可能源文件已被移动。")
        }

        do {
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: temporary, to: destination)
        } catch {
            try? manager.removeItem(at: temporary)
            throw AirliftError.failed("保存「\(destination.lastPathComponent)」失败：\(error.localizedDescription)")
        }
    }

    static func uniqueDestination(for fileName: String) -> URL {
        let manager = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    static func sizeOfItem(at url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }

        var total: Int64 = 0
        if let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            while let item = enumerator.nextObject() as? URL {
                if let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    // MARK: - 删除

    func delete(_ item: WallpaperItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
    }

    // MARK: - 文档目录自动发现（AirDrop / 文件 App / 电脑导入）

    /// 递归扫描 Documents（含 Inbox、子目录），按扩展名或文件头识别壁纸包。
    func scanDocuments() -> ScanResult {
        let manager = FileManager.default
        let documents = Self.documentsDirectory
        var result = ScanResult()
        var seenNames = Set<String>()

        guard let enumerator = manager.enumerator(
            at: documents,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return result
        }

        while let item = enumerator.nextObject() as? URL {
            let name = item.lastPathComponent
            if name == "wallpapers.json" { continue }

            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isDirectory {
                // 已导入区不再重复扫
                if item.standardizedFileURL == Self.directory.standardizedFileURL {
                    enumerator.skipDescendants()
                    continue
                }
                result.scannedFolders += 1
                if Self.looksLikeWallpaperFolder(item),
                   seenNames.insert(name).inserted {
                    result.candidates.append(item)
                    enumerator.skipDescendants()
                }
                continue
            }

            result.scannedFiles += 1

            let fileExtension = item.pathExtension.lowercased()
            let matchedByName = Self.supportedExtensions.contains(fileExtension)
            let matchedByHeader = !matchedByName && Self.looksLikeZipNamed(name, at: item)
            guard matchedByName || matchedByHeader else { continue }
            guard seenNames.insert(name).inserted else { continue }
            result.candidates.append(item)
        }

        return result
    }

    /// 兼容旧调用：只返回候选文件。
    func discoverInDocuments() -> [URL] {
        return scanDocuments().candidates
    }

    /// 文件夹形式：自身就是 descriptor，或者是包了 PRBPosterExtensionDataStore 的容器。
    static func looksLikeWallpaperFolder(_ url: URL) -> Bool {
        let manager = FileManager.default
        let markers = [
            "providerInfo.plist",
            "versions",
            "Wallpaper.plist",
            "com.apple.posterkit.provider.descriptor.identifier",
            "Library/Application Support/PRBPosterExtensionDataStore"
        ]
        for marker in markers {
            if manager.fileExists(atPath: url.appendingPathComponent(marker).path) {
                return true
            }
        }
        return false
    }

    /// 名字不像壁纸包、但文件头是 zip 的也算（例如传输过程中扩展名被改掉）。
    private static func looksLikeZipNamed(_ name: String, at url: URL) -> Bool {
        let lower = name.lowercased()
        let hints = ["tendies", "poster", "wallpaper", "壁纸"]
        guard hints.contains(where: { lower.contains($0) }) else { return false }
        return ZipArchive.looksLikeZip(url)
    }
}
