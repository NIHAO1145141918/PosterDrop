//
//  PosterBoardInstaller.swift
//  PosterDrop
//
//  真正“写入并使用”的一层：
//    1. 解开壁纸包，取出每个 descriptor 目录
//    2. 随机化 descriptor / wallpaper 标识，避免与系统已有壁纸冲突
//    3. 通过 worse_query 沙箱扩展把目录注入 PRBPosterExtensionDataStore/<ver>/Extensions/<bundleID>/descriptors/<UUID>
//    4. iOS 18+ 额外双写 .Posters.<Name>App 容器（同一台设备上另一个容器）
//    5. 写入 com.apple.PosterBoard.unprotectedUserDefaults.plist，让系统重新索引壁纸
//    6. 由调用方触发 NeoSpring respring，壁纸立即出现在锁屏/墙纸设置里
//

import Foundation
import UIKit

struct InstallOptions {
    var structVersion: Int
    var resetProtections: Bool
    var dualInject: Bool

    static func automatic() -> InstallOptions {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return InstallOptions(
            structVersion: major >= 17 ? 61 : 59,
            resetProtections: true,
            dualInject: major >= 18
        )
    }
}

struct InstallReport {
    var injectedDescriptors: Int
    var failedItems: [String]
    var containerPath: String
    var didWritePreferences: Bool
}

final class PosterBoardInstaller {

    static let shared = PosterBoardInstaller()

    private let posterBoardBundleID = "com.apple.PosterBoard"

    // MARK: - 容器

    /// 走 worse_query 定位容器（不需要配对、不需要 VPN）。
    func detectContainer(group: String, manual: String?, log: @escaping (String) -> Void) async throws -> String {
        return try await runOffMain {
            guard let hit = ContainerLocator.findPosterBoard(group: group, manual: manual, log: log) else {
                throw PosterDropError.failed("没有找到 PosterBoard 容器")
            }
            return hit.path
        }
    }

    // MARK: - 注入

    func install(
        items: [WallpaperItem],
        containerPath: String,
        channel: FileChannel,
        options: InstallOptions,
        log: @escaping (String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws -> InstallReport {

        guard !items.isEmpty else {
            throw PosterDropError.failed("没有选中任何壁纸。")
        }

        var container = containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while container.hasSuffix("/") { container.removeLast() }
        guard !container.isEmpty else {
            throw PosterDropError.failed("PosterBoard 容器路径为空，请先在“诊断”里自动探测一次。")
        }

        emit(log, "🎯 目标容器：\(container)")
        emit(log, "🔌 写入通道：\(channel.label)")
        emit(log, "🧩 数据结构版本：\(options.structVersion)")

        // iOS 18+ 的 .Posters.<Name>App 是独立容器，先把它们定位好（只做一次）
        var dualChannels: [String: FileChannel] = [:]
        if options.dualInject, let direct = channel as? DirectChannel {
            let pairs = [
                ("com.apple.WallpaperKit.CollectionsPoster", "com.apple.Posters.CollectionsPosterApp"),
                ("com.apple.MercuryPoster", "com.apple.Posters.MercuryPosterApp")
            ]
            for (legacy, modern) in pairs {
                if let hit = ContainerLocator.find(bundleID: modern, group: direct.group, manual: nil, log: { line in
                    emit(log, "  · " + line)
                }) {
                    dualChannels[legacy] = DirectChannel(containerPath: hit.path, group: direct.group)
                }
            }
            emit(log, "  · 新容器定位：\(dualChannels.keys.sorted().joined(separator: ", "))")
        }

        var injected = 0
        var failures: [String] = []
        let total = Double(items.count)

        for (index, item) in items.enumerated() {
            emit(log, "")
            emit(log, "[\(index + 1)/\(items.count)] 处理「\(item.name)」…")

            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("posterdrop-stage-\(UUID().uuidString)", isDirectory: true)

            do {
                try await runOffMain {
                    try ArchiveInspector.extract(archive: item.fileURL, into: staging)
                }

                let folders = ArchiveInspector.descriptorFolders(in: staging)
                emit(log, "  · 找到 \(folders.count) 个 descriptor 目录")

                guard !folders.isEmpty else {
                    throw PosterDropError.failed("包里没有可用的 descriptor 目录")
                }

                for (folderIndex, folder) in folders.enumerated() {
                    let fallback = item.kind.bundleID
                    var extensionID = ArchiveInspector.bundleIdentifier(for: folder, fallback: fallback)
                    if extensionID.isEmpty { extensionID = fallback }

                    let seed = Int.random(in: 10000...99999)
                    Self.randomizeIdentifiers(in: folder, seed: seed)

                    let descriptorUUID = UUID().uuidString.uppercased()
                    let parent = "\(container)/Library/Application Support/PRBPosterExtensionDataStore/\(options.structVersion)/Extensions/\(extensionID)/descriptors"

                    emit(log, "  · [\(folderIndex + 1)/\(folders.count)] → \(extensionID) / \(descriptorUUID)")

                    try await runOffMain {
                        try channel.injectFolder(
                            folder: folder.path,
                            parent: parent,
                            destName: descriptorUUID
                        )
                    }
                    injected += 1

                    // iOS 18+ 的 .Posters.<Name>App 是独立容器；能定位到就再写一份，
                    // 定位不到（旧系统没有这个 App）就跳过，不影响主注入。
                    if options.dualInject,
                       let modernID = Self.modernBundleIdentifier(for: extensionID),
                       let dual = dualChannels[extensionID] {
                        let modernParent = "\(dual.containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(options.structVersion)/Extensions/\(modernID)/descriptors"
                        do {
                            try await runOffMain {
                                try dual.injectFolder(
                                    folder: folder.path,
                                    parent: modernParent,
                                    destName: descriptorUUID
                                )
                            }
                            emit(log, "    ↳ 已同步到 \(modernID)")
                        } catch {
                            // 新容器不存在属于正常情况，不视为失败
                            emit(log, "    ↳ 跳过新容器 \(modernID)（\(error.localizedDescription)）")
                        }
                    }
                }
            } catch {
                failures.append("\(item.name)：\(error.localizedDescription)")
                emit(log, "  ❌ \(error.localizedDescription)")
            }

            try? FileManager.default.removeItem(at: staging)
            progress(Double(index + 1) / total * 0.9)
        }

        if injected == 0 {
            let detail = failures.isEmpty ? "没有注入任何壁纸。" : failures.joined(separator: "\n")
            throw PosterDropError.failed(detail)
        }

        emit(log, "")
        emit(log, "🔄 正在刷新 PosterBoard 缓存…")
        let wrotePreferences = await writePreferences(
            containerPath: container,
            channel: channel,
            resetProtections: options.resetProtections,
            log: log
        )

        progress(1.0)

        return InstallReport(
            injectedDescriptors: injected,
            failedItems: failures,
            containerPath: container,
            didWritePreferences: wrotePreferences
        )
    }

    /// 单独刷新缓存（不注入壁纸），用于“壁纸已注入但没出现”的救急操作。
    @discardableResult
    func refreshCache(containerPath: String, channel: FileChannel, log: @escaping (String) -> Void) async -> Bool {
        var container = containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while container.hasSuffix("/") { container.removeLast() }
        guard !container.isEmpty else { return false }
        return await writePreferences(
            containerPath: container,
            channel: channel,
            resetProtections: true,
            log: log
        )
    }

    // MARK: - 偏好设置（触发重新索引）

    private func writePreferences(
        containerPath: String,
        channel: FileChannel,
        resetProtections: Bool,
        log: @escaping (String) -> Void
    ) async -> Bool {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterdrop-pref-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let plist: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": resetProtections,
            "PBF_LOCALE_DID_CHANGE": true,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp",
                "com.apple.WallpaperKit.CollectionsPoster",
                "com.apple.MercuryPoster",
                "com.apple.Posters.MercuryPosterApp",
                "com.apple.PhotosUIPrivate.PhotosPosterProvider"
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
            ]
        ]

        let plistURL = staging.appendingPathComponent("com.apple.PosterBoard.unprotectedUserDefaults.plist")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try data.write(to: plistURL)
        } catch {
            emit(log, "  ⚠️ 偏好设置生成失败：\(error.localizedDescription)")
            return false
        }

        let target = "\(containerPath)/Library/Preferences"

        do {
            try await runOffMain {
                try channel.writeTree(source: staging.path, target: target)
            }
            emit(log, "  ✓ 已写入 \(target)")
            return true
        } catch {
            emit(log, "  ⚠️ 写入 \(target) 失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 标识随机化

    /// 只在“没有 suggestionMetadata”的模板里随机化，且只改写纯数字标识，
    /// 否则会破坏 Mercury / Unity / Kaleidoscope 这类按符号名查找的扩展。
    static func randomizeIdentifiers(in folder: URL, seed: Int) {
        let metadataURL = folder.appendingPathComponent("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")
        if FileManager.default.fileExists(atPath: metadataURL.path) { return }

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let fileURL = enumerator.nextObject() as? URL {
            let name = fileURL.lastPathComponent

            if name == "com.apple.posterkit.provider.descriptor.identifier" {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8),
                   Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) != nil,
                   let data = "\(seed)".data(using: .utf8) {
                    try? data.write(to: fileURL)
                }
                continue
            }

            if name == "com.apple.posterkit.provider.contents.userInfo" {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)) as? [String: Any],
                   plist["wallpaperRepresentingIdentifier"] != nil {
                    plist["wallpaperRepresentingIdentifier"] = seed
                    if let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                        try? updated.write(to: fileURL)
                    }
                }
                continue
            }

            if name.hasSuffix("Wallpaper.plist") {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)) as? [String: Any] {
                    plist["identifier"] = seed
                    if let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                        try? updated.write(to: fileURL)
                    }
                }
            }
        }
    }

    static func modernBundleIdentifier(for extensionID: String) -> String? {
        if extensionID == "com.apple.WallpaperKit.CollectionsPoster" {
            return "com.apple.Posters.CollectionsPosterApp"
        }
        if extensionID == "com.apple.MercuryPoster" {
            return "com.apple.Posters.MercuryPosterApp"
        }
        return nil
    }

    // MARK: - 工具

    private func emit(_ log: @escaping (String) -> Void, _ line: String) {
        DispatchQueue.main.async {
            log(line)
        }
    }

    private func runOffMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
