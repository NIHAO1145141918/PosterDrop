//
//  FileChannel.swift
//  PosterDrop
//
//  写入通道：只有一条——worse_query 签发的沙箱扩展。
//
//  worse_query 的一条实测结论（27.0.1）：扩展只覆盖签发时指定的那一个目录，
//  “给容器根签发”并不足以在两三层之下创建文件。所以这里的做法是：
//  每建一层目录、每写一层文件，都先给文件真正所在的目录单独签发一次。
//

import Foundation
import Darwin

protocol FileChannel: AnyObject {
    /// 展示用名称
    var label: String { get }
    /// 签发扩展用的 App Group
    var group: String { get }

    /// 把一个本地目录整体写成 parent/destName
    func injectFolder(folder: String, parent: String, destName: String) throws
    /// 把本地目录里的文件平铺写进已存在的 target
    func writeTree(source: String, target: String) throws
}

/// 自检结果：报告文本 + 真正可用的容器路径（有就顺手存下来）。
struct ProbeResult: Sendable {
    let report: String
    let containerPath: String?
}

final class DirectChannel: FileChannel, @unchecked Sendable {

    let containerPath: String
    let group: String

    init(containerPath: String, group: String) {
        self.containerPath = containerPath
        self.group = group
    }

    var label: String { "worse_query（App Group \(group)）" }

    // MARK: 定位

    static func locate(group: String, manualContainer: String?, log: @escaping (String) -> Void) throws -> DirectChannel {
        guard let hit = ContainerLocator.findPosterBoard(group: group, manual: manualContainer, log: log) else {
            throw SandboxEscape.Failure(
                code: -11,
                message: "没有找到 PosterBoard 容器。可以先在诊断页点「自检通道」看卡在哪一步；仍然失败时，用 WQFiles 打开 App Data › PosterBoard，复制容器路径填到诊断页。"
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
            lines.append("worse_query 必须有 com.apple.security.application-groups。")
            lines.append("用 轻松签 / ESign / SideStore 重签时勾选 App Groups（免费 Personal Team 也能签）。")
            return ProbeResult(report: lines.joined(separator: "\n"), containerPath: nil)
        }
        lines.append("使用的 App Group：\(group)")
        lines.append("系统：iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        do {
            let channel = try locate(group: group, manualContainer: manualContainer, log: { lines.append($0) })
            lines.append("✅ 容器可用，可以直接应用壁纸")
            return ProbeResult(report: lines.joined(separator: "\n"), containerPath: channel.containerPath)
        } catch {
            lines.append("❌ \(error.localizedDescription)")
            return ProbeResult(report: lines.joined(separator: "\n"), containerPath: nil)
        }
    }

    // MARK: 目录与授权

    /// 给目录（或文件）本身签发扩展；写操作会额外做探针验证。
    /// 不在本地另做缓存：SandboxEscape 有全局上限和淘汰机制，这里的二次缓存会让
    /// “以为有权限、实际扩展已被释放”的情况发生。
    private func ensureGranted(_ path: String, writable: Bool) throws {
        let canonical = SandboxEscape.canonicalPath(path)
        do {
            _ = try SandboxEscape.grant(path: canonical, group: group, requireWrite: writable)
        } catch let failure as SandboxEscape.Failure {
            throw SandboxEscape.Failure(code: failure.code, message: "无法获得 \(canonical) 的访问权限：\(failure.message)")
        }
    }

    /// 保证目录存在，并且“这个目录本身”已经被扩展覆盖（可以往里写文件）。
    private func ensureDirectory(_ path: String) throws {
        let canonical = SandboxEscape.canonicalPath(path)
        let fileManager = FileManager.default

        var missing: [String] = []
        var current = canonical
        while !fileManager.fileExists(atPath: current), current != "/" {
            missing.append(current)
            current = (current as NSString).deletingLastPathComponent
        }

        if missing.isEmpty {
            try ensureGranted(canonical, writable: true)
            return
        }

        try ensureGranted(current, writable: true)
        for directory in missing.reversed() {
            do {
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: false)
            } catch {
                throw SandboxEscape.Failure(code: -12, message: "创建目录 \(directory) 失败：\(error.localizedDescription)")
            }
            // 新建的目录需要自己的扩展，下一层才能在它里面创建东西
            try ensureGranted(directory, writable: true)
        }
    }

    // MARK: 写入

    func injectFolder(folder: String, parent: String, destName: String) throws {
        let fileManager = FileManager.default
        try ensureDirectory(parent)

        let destination = SandboxEscape.canonicalPath(parent) + "/" + destName
        if fileManager.fileExists(atPath: destination) {
            // 目录树里每一层都要写权限才能删；先改名放到一边，失败也不影响本次写入
            let old = SandboxEscape.canonicalPath(parent) + "/.pd-old-" + UUID().uuidString
            try? fileManager.moveItem(atPath: destination, toPath: old)
            if fileManager.fileExists(atPath: old) {
                try? fileManager.removeItem(atPath: old)
            }
        }

        try ensureDirectory(destination)
        try copyContents(from: folder, to: destination)

        let sourceCount = countFiles(in: folder)
        let targetCount = countFiles(in: destination)
        guard sourceCount == targetCount else {
            throw SandboxEscape.Failure(
                code: -13,
                message: "写入不完整：源 \(sourceCount) 个文件，目标 \(targetCount) 个（\(destination)）"
            )
        }
    }

    func writeTree(source: String, target: String) throws {
        let fileManager = FileManager.default
        try ensureDirectory(target)

        let items = try fileManager.contentsOfDirectory(atPath: source)
        for item in items {
            let from = source + "/" + item
            let to = SandboxEscape.canonicalPath(target) + "/" + item
            if fileManager.fileExists(atPath: to) {
                try? fileManager.removeItem(atPath: to)
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: from, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try ensureDirectory(to)
                try copyContents(from: from, to: to)
            } else {
                try copyFile(from: from, to: to)
            }
        }
    }

    private func copyContents(from source: String, to destination: String) throws {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(atPath: source)
        for item in items {
            let from = source + "/" + item
            let to = destination + "/" + item
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: from, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try ensureDirectory(to)
                try copyContents(from: from, to: to)
            } else {
                try copyFile(from: from, to: to)
            }
        }
    }

    /// 用 read/write 分块拷贝，不用 FileManager.copyItem：
    /// copyfile(3) 会顺带复制 xattr / ACL，在别人的容器里常因元数据写入被拒而整次失败；
    /// 流式写入只要求目标目录的写权限，和 WQFiles 的做法一致。
    private func copyFile(from source: String, to destination: String) throws {
        let parent = (destination as NSString).deletingLastPathComponent
        try ensureGranted(parent, writable: true)

        let input = open(source, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else {
            throw SandboxEscape.Failure(code: -13, message: "读取 \(source) 失败（errno \(errno)）")
        }
        defer { close(input) }

        unlink(destination)
        var output = open(destination, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if output < 0 && (errno == EPERM || errno == EACCES) {
            // 扩展可能在这一轮被淘汰：重新签发再试一次
            _ = try? SandboxEscape.grant(path: parent, group: group, requireWrite: true)
            output = open(destination, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        }
        guard output >= 0 else {
            throw SandboxEscape.Failure(code: -13, message: "写入 \(destination) 失败（errno \(errno)）")
        }
        defer { close(output) }

        let chunk = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let readCount = read(input, buffer, chunk)
            if readCount < 0 && errno == EINTR { continue }
            guard readCount >= 0 else {
                throw SandboxEscape.Failure(code: -13, message: "读取 \(source) 失败（errno \(errno)）")
            }
            if readCount == 0 { break }

            var written = 0
            while written < readCount {
                let count = write(output, buffer.advanced(by: written), readCount - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw SandboxEscape.Failure(code: -13, message: "写入 \(destination) 失败（errno \(errno)）")
                }
                written += count
            }
        }
        fsync(output)
    }

    private func countFiles(in root: String) -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: root) else { return 0 }
        var count = 0
        for case let relative as String in enumerator {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: root + "/" + relative, isDirectory: &isDirectory), !isDirectory.boolValue {
                count += 1
            }
        }
        return count
    }
}
