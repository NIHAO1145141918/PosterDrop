//
//  FileChannel.swift
//  PosterDrop
//
//  写入通道抽象：
//    · TunnelChannel —— 走配对隧道（Airlift），iOS 18+ 通用，需要配对记录；
//    · DirectChannel —— 走沙箱扩展（直连），不需要配对，但要系统存在签发缺陷。
//
//  两者对上层是同一套接口，注入逻辑不关心文件到底怎么落到设备上。
//

import Foundation

protocol FileChannel: AnyObject {
    /// 展示用名称
    var label: String { get }
    /// 是否能写 /var/mobile/Library/Preferences（只有隧道可以）
    var supportsGlobalPreferences: Bool { get }

    /// 把一个本地目录整体写成 parent/destName
    func injectFolder(folder: String, parent: String, destName: String) throws
    /// 把本地目录里的文件平铺写进已存在的 target
    func writeTree(source: String, target: String) throws
}

// MARK: - 隧道通道

final class TunnelChannel: FileChannel {

    let pairingPath: String

    init(pairingPath: String) {
        self.pairingPath = pairingPath
    }

    var label: String { "配对隧道" }
    var supportsGlobalPreferences: Bool { true }

    func injectFolder(folder: String, parent: String, destName: String) throws {
        try Airlift.injectFolder(pairingPath: pairingPath, folder: folder, parent: parent, destName: destName)
    }

    func writeTree(source: String, target: String) throws {
        try Airlift.writeDirectory(pairingPath: pairingPath, source: source, target: target)
    }
}

// MARK: - 直连通道

/// 持有若干沙箱扩展；只要它活着，本进程就能直接读写目标容器。
final class DirectChannel: FileChannel, @unchecked Sendable {

    let containerPath: String
    private let rootSession: EscapeSession
    private let containerSession: EscapeSession

    init(containerPath: String, rootSession: EscapeSession, containerSession: EscapeSession) {
        self.containerPath = containerPath
        self.rootSession = rootSession
        self.containerSession = containerSession
    }

    var label: String { "直连（\(rootSession.label)）" }
    var supportsGlobalPreferences: Bool { false }

    // MARK: 定位

    private static let applicationsRoot = "/var/mobile/Containers/Data/Application"

    /// 打开直连通道：先拿到 Application 根目录的扩展，再逐个容器找 PosterBoard。
    static func locate(mode: SandboxEscape.Mode) throws -> DirectChannel {
        let fileManager = FileManager.default

        let rootSession = try SandboxEscape.acquire(target: applicationsRoot, mode: mode)

        let children: [String]
        do {
            children = try fileManager.contentsOfDirectory(atPath: applicationsRoot)
        } catch {
            throw SandboxEscape.Failure(code: -10, message: "拿到扩展后仍无法列目录：\(error.localizedDescription)")
        }

        for child in children {
            let candidate = applicationsRoot + "/" + child
            let marker = candidate + "/Library/Application Support/PRBPosterExtensionDataStore"
            guard fileManager.fileExists(atPath: marker) else { continue }

            // 根扩展通常已递归覆盖子树；这里再单独申请一次，兼容不递归的实现
            let containerSession = (try? SandboxEscape.acquire(target: candidate, mode: mode)) ?? rootSession
            return DirectChannel(
                containerPath: candidate,
                rootSession: rootSession,
                containerSession: containerSession
            )
        }

        throw SandboxEscape.Failure(code: -11, message: "在 \(children.count) 个容器里没有找到 PosterBoard")
    }

    /// 只做探测，不安装：给诊断页用。
    static func probe(mode: SandboxEscape.Mode) -> String {
        let fileManager = FileManager.default
        var lines: [String] = []
        lines.append("跳板：\(mode.label)")

        let rootSession: EscapeSession
        do {
            rootSession = try SandboxEscape.acquire(target: applicationsRoot, mode: mode)
        } catch {
            lines.append("❌ 申请扩展失败：\(error.localizedDescription)")
            return lines.joined(separator: "\n")
        }
        defer { withExtendedLifetime(rootSession) {} }
        lines.append("✅ 已获得 \(applicationsRoot) 的沙箱扩展")

        guard let children = try? fileManager.contentsOfDirectory(atPath: applicationsRoot) else {
            lines.append("❌ 列目录失败")
            return lines.joined(separator: "\n")
        }
        lines.append("可见容器：\(children.count) 个")

        var hits: [String] = []
        for child in children {
            let candidate = applicationsRoot + "/" + child
            let marker = candidate + "/Library/Application Support/PRBPosterExtensionDataStore"
            if fileManager.fileExists(atPath: marker) {
                hits.append(candidate)
            }
        }

        if hits.isEmpty {
            lines.append("❌ 没有找到带 PRBPosterExtensionDataStore 的容器")
        } else {
            lines.append("✅ PosterBoard 容器：\(hits[0])")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 写入

    func injectFolder(folder: String, parent: String, destName: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let destination = parent + "/" + destName
        if fileManager.fileExists(atPath: destination) {
            try? fileManager.removeItem(atPath: destination)
        }
        try fileManager.copyItem(atPath: folder, toPath: destination)
    }

    func writeTree(source: String, target: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: target, withIntermediateDirectories: true)

        let items = try fileManager.contentsOfDirectory(atPath: source)
        for item in items {
            let from = source + "/" + item
            let to = target + "/" + item
            if fileManager.fileExists(atPath: to) {
                try? fileManager.removeItem(atPath: to)
            }
            try fileManager.copyItem(atPath: from, toPath: to)
        }
    }
}
