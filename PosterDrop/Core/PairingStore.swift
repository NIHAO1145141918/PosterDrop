//
//  PairingStore.swift
//  PosterDrop
//
//  配对记录（.mobiledevicepairing / .plist）的导入、校验与规范化存放。
//  没有有效配对记录时，Airlift 无法与设备自身的 lockdown / RSD 服务通信。
//

import Foundation

struct PairingCandidate: Identifiable {
    var id: String { url.path }
    let url: URL
    let size: Int
    let source: String
}

final class PairingStore {

    static let shared = PairingStore()

    private static let altIRKKey = "posterdrop.pairingHostAltIRK"

    static var documentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 规范化后的配对文件路径（Rust 侧只认这一个）
    static var canonicalURL: URL {
        return documentsDirectory.appendingPathComponent("pairing.plist")
    }

    /// 当前可用的配对文件路径；没有则返回规范化路径（文件不存在）。
    var activePath: String {
        if Self.fileSize(at: Self.canonicalURL) > 0 {
            return Self.canonicalURL.path
        }
        if let discovered = discoveredPairingFiles().first {
            _ = try? adopt(url: discovered.url)
            return Self.canonicalURL.path
        }
        return Self.canonicalURL.path
    }

    var hasValidPairing: Bool {
        return Self.fileSize(at: Self.canonicalURL) > 0
    }

    var activePairingSize: Int {
        return Self.fileSize(at: Self.canonicalURL)
    }

    // MARK: - AltIRK（保持本机 host 身份稳定）

    var storedAltIRK: String {
        get { UserDefaults.standard.string(forKey: Self.altIRKKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.altIRKKey) }
    }

    // MARK: - 导入 / 采纳

    @discardableResult
    func adopt(url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AirliftError.failed("读取配对文件失败：\(error.localizedDescription)")
        }

        guard !data.isEmpty else {
            throw AirliftError.failed("配对文件内容为空，请重新导出或重新配对。")
        }

        // 必须是 plist，否则一定不是配对记录
        guard (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil else {
            throw AirliftError.failed("这不是有效的配对 plist 文件。")
        }

        try data.write(to: Self.canonicalURL, options: .atomic)
        return data.count
    }

    func deleteCredentials() {
        try? FileManager.default.removeItem(at: Self.canonicalURL)
        storedAltIRK = ""
    }

    // MARK: - 发现

    /// 在 Documents（含子目录，最多两层）里寻找可能的配对文件。
    func discoveredPairingFiles() -> [PairingCandidate] {
        let documents = Self.documentsDirectory
        var results: [PairingCandidate] = []

        let knownNames = ["pairing.plist", "airlift_pairing.plist", "aircard_pairing.plist"]
        let knownExtensions: Set<String> = ["mobiledevicepairing", "mobilepair", "plist"]

        func inspect(_ url: URL, depth: Int) {
            guard depth <= 2 else { return }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for item in contents {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    inspect(item, depth: depth + 1)
                    continue
                }

                let extensionName = item.pathExtension.lowercased()
                let name = item.lastPathComponent.lowercased()
                let isKnownName = knownNames.contains(name)
                guard knownExtensions.contains(extensionName) || isKnownName else { continue }

                let size = Self.fileSize(at: item)
                guard size > 0 else { continue }
                if item.standardizedFileURL.path == Self.canonicalURL.standardizedFileURL.path { continue }

                let source = item.deletingLastPathComponent().lastPathComponent
                results.append(PairingCandidate(url: item, size: size, source: source))
            }
        }

        inspect(documents, depth: 0)
        results.sort { $0.url.path.count < $1.url.path.count }
        return results
    }

    // MARK: - 工具

    static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}
