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

/// 自检结果：报告文本 + 真正可用的容器路径（有就顺手存下来）。
struct ProbeResult: Sendable {
    let report: String
    let containerPath: String?
}

/// 借 App Group 的沙箱扩展直接写 PosterBoard 容器。
/// 每次落盘前都确保目标路径（或最近的已存在父目录）已被扩展覆盖。
final class DirectChannel: FileChannel, @unchecked Sendable {

    let containerPath: String
    let group: String

    init(containerPath: String, group: String) {
        self.containerPath = containerPath
        self.group = group
    }

    var label: String { "直连（App Group \(group)）" }
    var supportsGlobalPreferences: Bool { false }

    // MARK: 定位

    static func locate(group: String, manualContainer: String?, log: @escaping (String) -> Void) throws -> DirectChannel {
        guard let hit = ContainerLocator.findPosterBoard(group: group, manual: manualContainer, log: log) else {
            throw SandboxEscape.Failure(
                code: -11,
                message: "没有找到 PosterBoard 容器：去 WQFiles 的「App Data › PosterBoard」长按复制容器路径，粘贴到诊断页的输入框再试"
            )
        }
        log("🎯 PosterBoard 容器（\(hit.source)）：\(hit.path)")
        return DirectChannel(containerPath: hit.path, group: group)
    }

    /// 只做探测，不安装：给诊断页用。
    static func probe(group: String?, manualContainer: String?) -> ProbeResult {
        var lines: [String] = []

        let groups = SandboxEscape.entitledGroups()
        lines.append("签名内 App Groups：\(groups.isEmpty ? "无" : groups.joined(separator: ", "))")

        guard let group = SandboxEscape.usableGroup(preferred: group) else {
            lines.append("❌ 没有可用的 App Group 容器")
            lines.append("这条通道要求签名里带 com.apple.security.application-groups。")
            lines.append("用 轻松签 / ESign 重签时勾选 App Groups，或用一个允许 App Groups 的 profile（含免费 Personal Team）。")
            return ProbeResult(report: lines.joined(separator: "\n"), containerPath: nil)
        }
        lines.append("使用的 App Group：\(group)")

        do {
            let channel = try locate(group: group, manualContainer: manualContainer, log: { lines.append($0) })
            lines.append("✅ 容器可用，可以直接应用壁纸")
            return ProbeResult(report: lines.joined(separator: "\n"), containerPath: channel.containerPath)
        } catch {
            lines.append("❌ \(error.localizedDescription)")
            return ProbeResult(report: lines.joined(separator: "\n"), containerPath: nil)
        }
    }

    // MARK: 写入

    /// 确保目录存在且已被扩展覆盖。
    private func prepareDirectory(_ path: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            _ = try? SandboxEscape.grant(path: path, group: group)
            return
        }
        // 不存在的部分：先授权最近的已存在祖先，再逐级创建
        guard SandboxEscape.grantNearestExisting(path: path, group: group) != nil else {
            throw SandboxEscape.Failure(code: -12, message: "无法为 \(path) 申请沙箱扩展")
        }
        do {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw SandboxEscape.Failure(code: -12, message: "创建目录失败：\(error.localizedDescription)")
        }
        _ = try? SandboxEscape.grant(path: path, group: group)
    }

    func injectFolder(folder: String, parent: String, destName: String) throws {
        let fileManager = FileManager.default
        try prepareDirectory(parent)

        let destination = parent + "/" + destName
        if fileManager.fileExists(atPath: destination) {
            try? fileManager.removeItem(atPath: destination)
        }
        do {
            try fileManager.copyItem(atPath: folder, toPath: destination)
        } catch {
            throw SandboxEscape.Failure(code: -13, message: "写入 \(destination) 失败：\(error.localizedDescription)")
        }
    }

    func writeTree(source: String, target: String) throws {
        let fileManager = FileManager.default
        try prepareDirectory(target)

        let items = try fileManager.contentsOfDirectory(atPath: source)
        for item in items {
            let from = source + "/" + item
            let to = target + "/" + item
            if fileManager.fileExists(atPath: to) {
                try? fileManager.removeItem(atPath: to)
            }
            do {
                try fileManager.copyItem(atPath: from, toPath: to)
            } catch {
                throw SandboxEscape.Failure(code: -13, message: "写入 \(to) 失败：\(error.localizedDescription)")
            }
        }
    }
}
