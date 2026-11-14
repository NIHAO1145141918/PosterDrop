//
//  CacheCleaner.swift
//  PosterDrop
//
//  缓存清理：把「占地方、删掉会自动重建」的数据清掉。
//
//  三条铁律（比功能本身重要）：
//    1. 只删白名单目录。路径一律由「合法容器根 + 固定相对路径」拼出来，
//       不接受界面上传进来的任意路径，从根上杜绝「少拼一层删到 Documents」；
//    2. 符号链接只删链接本身，绝不跟进去 —— App Group 的 Library/Caches 就是符号链接，
//       跟进去会删到别的容器；
//    3. 删除前先给「父目录」签发写扩展，子目录清空后才 rmdir，链接一律 unlink。
//       扩展只覆盖签发的那一个目录，这一条不能省。
//
//  覆盖范围（按「删了会怎样」分层）：
//    · 可重建：Caches / tmp / SplashBoard / Saved Application State / Logs
//    · 需重登：Cookies / WebKit / HTTPStorages
//    · 系统级：全系统应用快照 / 崩溃日志 / 共享缓存（默认不勾）
//
//  性能：
//    - 整轮清理包在 beginBatch / endBatch 里，Caches 符号链接只装一次；
//    - 遍历用 opendir + lstat，不构造 URL，十万级文件也能在秒级走完；
//    - 读/写失败（EPERM）才补签扩展，正常情况下一次签发覆盖整棵子树。
//

import Foundation
import Darwin

// MARK: - 目标

struct CacheTarget: Identifiable, Equatable, Sendable {

    enum Scope: String, Sendable {
        /// 本 App 自己的临时目录与缓存，不需要沙箱扩展
        case app
        /// PosterBoard 容器的缓存
        case posterBoard
        /// 其他 App 的缓存，逐个 App 一项
        case other
        /// 系统级共享缓存，跨 App 生效
        case system
    }

    enum State: Equatable, Sendable {
        case pending
        case ready
        case empty
        case missing
        case denied
    }

    let id: String
    let scope: Scope
    let title: String
    /// 副标题：bundle id 或路径说明，放在标题下方一行小字
    let subtitle: String?
    let detail: String
    /// 要遍历的根目录（一个 App 可能是多个白名单目录）
    let paths: [String]
    /// 只清理顶层名字带这个前缀的条目（本 App 的 tmp 里只动自己的 stage 目录）
    let prefixFilter: String?
    /// 是否需要 worse_query 沙箱扩展
    let needsEscape: Bool
    /// 首次扫描时默认勾选
    let recommended: Bool
    /// 额外的风险提示
    let caution: String?

    var bytes: Int64 = 0
    var files: Int = 0
    var state: State = .pending
    var isSelected: Bool = false

    var sizeText: String { CacheFormat.size(bytes) }

    var isCleanable: Bool { state == .ready && (bytes > 0 || files > 0) }
}

// MARK: - 数字格式

enum CacheFormat {

    /// 1024 进制，和系统「iPhone 储存空间」的读数一致。
    static func size(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        if value >= 100 { return String(format: "%.0f %@", value, units[index]) }
        if value >= 10 { return String(format: "%.1f %@", value, units[index]) }
        return String(format: "%.2f %@", value, units[index])
    }

    static func count(_ files: Int) -> String {
        if files >= 10_000 { return "1 万+ 个文件" }
        return "\(files) 个文件"
    }
}

// MARK: - 清理器

final class CacheCleaner: @unchecked Sendable {

    static let shared = CacheCleaner()

    private init() {}

    // MARK: 白名单

    /// 容器内允许清理的相对路径。只有这里列出来的位置会被删。
    private struct Entry {
        let rel: String
        let title: String
        let detail: String
        let recommended: Bool
        let caution: String?
    }

    /// 容器内可清理的位置。分三档：可重建、需重新登录、日志类。
    private static let containerEntries: [Entry] = [
        Entry(
            rel: "Library/Caches",
            title: "缓存与缩略图",
            detail: "渲染时生成的缩略图、预览图和下载缓存，删掉后系统会自己重建",
            recommended: true,
            caution: nil
        ),
        Entry(
            rel: "tmp",
            title: "临时文件",
            detail: "扩展之间交换数据用的临时目录，随时可以清空",
            recommended: true,
            caution: nil
        ),
        Entry(
            rel: "Library/SplashBoard",
            title: "应用快照",
            detail: "切到后台时的界面截图，删掉后下次重新截一张",
            recommended: false,
            caution: nil
        ),
        Entry(
            rel: "Library/Saved Application State",
            title: "窗口状态存档",
            detail: "上次退出时的界面状态，只影响「回到上一次的位置」",
            recommended: false,
            caution: "清掉后重新打开可能回到首页"
        ),
        Entry(
            rel: "Library/HTTPStorages",
            title: "网络缓存",
            detail: "HTTP 缓存与 Cookie 数据库，图片和接口响应会重新下载",
            recommended: false,
            caution: "清掉后需要重新登录"
        ),
        Entry(
            rel: "Library/Cookies",
            title: "Cookies",
            detail: "网站与账号的登录会话",
            recommended: false,
            caution: "清掉后所有网页登录都会退出"
        ),
        Entry(
            rel: "Library/WebKit",
            title: "网页数据",
            detail: "内置浏览器留下的页面缓存、LocalStorage 与 IndexedDB",
            recommended: false,
            caution: "清掉后网页需要重新加载"
        ),
        Entry(
            rel: "Library/Logs",
            title: "运行日志",
            detail: "诊断日志与崩溃转储，删掉不影响功能",
            recommended: false,
            caution: nil
        )
    ]

    /// 系统级路径：跨 App 生效，默认不勾，必须精确命中白名单才允许删。
    private struct SystemEntry {
        let path: String
        let title: String
        let detail: String
        let caution: String?
    }

    private static let systemEntries: [SystemEntry] = [
        SystemEntry(
            path: "/private/var/mobile/Library/SplashBoard/Snapshots",
            title: "全系统应用快照",
            detail: "所有 App 的后台界面截图，通常是这类清理里最大的一块",
            caution: "所有 App 的后台预览都会重拍，切换动画会短暂变慢"
        ),
        SystemEntry(
            path: "/private/var/mobile/Library/Logs/CrashReporter",
            title: "崩溃日志",
            detail: "系统与各 App 的崩溃报告，删掉不影响功能",
            caution: nil
        ),
        SystemEntry(
            path: "/private/var/mobile/Library/Caches",
            title: "系统共享缓存",
            detail: "SpringBoard 图标缓存、系统服务缓存，删掉后桌面会重建一次",
            caution: "桌面图标与壁纸可能短暂重载，建议清理后 respring"
        )
    ]

    /// 系统级白名单。删除前会做「完全相等或在其之下」的校验。
    private static let systemAllowlist: [String] = systemEntries.map(\.path)

    /// 单个目标的遍历预算：一个 App 的缓存目录再大也看得完，又不至于把扫描拖成分钟级。
    private static let measureBudget = 50_000
    /// 最长递归深度，挡住异常深的目录树。
    private static let maxDepth = 20
    /// 深度扫描最多看多少个容器。
    private static let otherScanLimit = 200
    /// 列表里最多展示多少个 App（按占用从大到小）。
    private static let otherDisplayLimit = 60

    // MARK: - 扫描

    /// 统计所有缓存项。`includeOthers` 为 true 时才会去扫别的 App（慢，几秒）。
    func scan(
        container: String?,
        group: String?,
        includeOthers: Bool,
        log: @escaping (String) -> Void
    ) -> [CacheTarget] {

        var targets = makeAppTargets()

        if let container, isValidContainer(container) {
            targets += makePosterBoardTargets(container: SandboxEscape.canonicalPath(container))
        }

        // 整轮统计共用一次 Caches 交换：几百个容器逐个签发时，这是唯一不卡住的地方
        let needsEscape = targets.contains { $0.needsEscape }
        if needsEscape, let group {
            SandboxEscape.beginBatch(group: group)
        }
        defer {
            if needsEscape, group != nil {
                SandboxEscape.endBatch()
            }
        }

        var measured = targets.map { target in
            var budget = Self.measureBudget
            return measure(target, group: target.needsEscape ? group : nil, budget: &budget)
        }

        if includeOthers, let group {
            measured.append(contentsOf: scanOtherApps(group: group, log: log))
        }

        // 系统级三项：不需要容器，路径固定
        measured.append(contentsOf: makeSystemTargets().map { target in
            var budget = Self.measureBudget
            return measure(target, group: group, budget: &budget)
        })

        // 其他 App 按占用从大到小，空的不占位置
        let othersSorted = measured
            .filter { $0.scope == .other }
            .sorted { $0.bytes > $1.bytes }
            .prefix(Self.otherDisplayLimit)

        var ordered: [CacheTarget] = measured.filter { $0.scope != .other }
        let insertAt = ordered.firstIndex { $0.scope == .system } ?? ordered.count
        ordered.insert(contentsOf: othersSorted, at: insertAt)
        return ordered
    }

    // MARK: 本 App

    private func makeAppTargets() -> [CacheTarget] {
        var targets: [CacheTarget] = [
            CacheTarget(
                id: "app.staging",
                scope: .app,
                title: "解包暂存",
                subtitle: nil,
                detail: "导入壁纸时解压出的临时目录，任务中断会残留在这里",
                paths: [SandboxEscape.canonicalPath(NSTemporaryDirectory())],
                prefixFilter: "posterdrop-",
                needsEscape: false,
                recommended: true,
                caution: nil
            )
        ]

        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            targets.append(
                CacheTarget(
                    id: "app.caches",
                    scope: .app,
                    title: "本 App 缓存",
                    subtitle: nil,
                    detail: "索引与界面缓存，删掉后会自动重建",
                    paths: [SandboxEscape.canonicalPath(caches.path)],
                    prefixFilter: nil,
                    needsEscape: false,
                    recommended: true,
                    caution: nil
                )
            )
        }

        return targets
    }

    // MARK: PosterBoard

    private func makePosterBoardTargets(container: String) -> [CacheTarget] {
        return Self.containerEntries.map { entry in
            CacheTarget(
                id: "pb." + entry.rel,
                scope: .posterBoard,
                title: entry.title,
                subtitle: nil,
                detail: entry.detail,
                paths: [container + "/" + entry.rel],
                prefixFilter: nil,
                needsEscape: true,
                recommended: entry.recommended,
                caution: entry.caution
            )
        }
    }

    // MARK: 系统级

    private func makeSystemTargets() -> [CacheTarget] {
        Self.systemEntries.map { entry in
            CacheTarget(
                id: "sys." + entry.path,
                scope: .system,
                title: entry.title,
                subtitle: entry.path.replacingOccurrences(of: "/private/var/mobile/", with: "~/"),
                detail: entry.detail,
                paths: [entry.path],
                prefixFilter: nil,
                needsEscape: true,
                recommended: false,
                caution: entry.caution
            )
        }
    }

    // MARK: 其他 App

    /// 每个 App 一项：只把真实存在的白名单目录塞进去，扫完按大小排序。
    private func scanOtherApps(
        group: String,
        log: @escaping (String) -> Void
    ) -> [CacheTarget] {
        let containers = ContainerLocator.discoverContainers(log: log)
        guard !containers.isEmpty else {
            log("没有发现其他 App 的容器，跳过")
            return []
        }

        let posterBoard = ContainerLocator.rememberedContainerPath(for: ContainerLocator.posterBoardBundleID)
        let posterCanonical = posterBoard.map { SandboxEscape.canonicalPath($0) }

        var results: [CacheTarget] = []
        var scanned = 0

        for container in containers.prefix(Self.otherScanLimit) {
            let canonical = SandboxEscape.canonicalPath(container)
            if let posterCanonical, canonical == posterCanonical { continue }

            scanned += 1
            if scanned % 25 == 0 {
                log("其他 App：已扫描 \(scanned) 个容器…")
            }

            // 容器根签发一次，能覆盖子树时后续判断都便宜；覆盖不了会在 measure 里补签
            _ = try? SandboxEscape.grant(path: canonical, group: group)

            var paths: [String] = []
            var labels: [String] = []
            for entry in Self.containerEntries {
                let path = canonical + "/" + entry.rel
                if SandboxEscape.exists(path) {
                    paths.append(path)
                    labels.append(shortLabel(entry.rel))
                }
            }
            guard !paths.isEmpty else { continue }

            let identifier = SandboxEscape.containerIdentifier(at: canonical)
            let identifierText = (identifier?.isEmpty == false) ? identifier : nil
            let title = identifierText ?? (canonical as NSString).lastPathComponent

            results.append(
                CacheTarget(
                    id: "other." + canonical,
                    scope: .other,
                    title: title,
                    subtitle: identifierText == nil ? (canonical as NSString).lastPathComponent : nil,
                    detail: "\(paths.count) 项：" + labels.joined(separator: "、"),
                    paths: paths,
                    prefixFilter: nil,
                    needsEscape: true,
                    recommended: false,
                    caution: nil
                )
            )
        }

        log("其他 App：扫描 \(scanned) 个容器，\(results.count) 个有缓存")
        return results
    }

    private func shortLabel(_ rel: String) -> String {
        switch rel {
        case "Library/Caches": return "缓存"
        case "tmp": return "tmp"
        case "Library/SplashBoard": return "快照"
        case "Library/Saved Application State": return "窗口状态"
        case "Library/HTTPStorages": return "网络缓存"
        case "Library/Cookies": return "Cookie"
        case "Library/WebKit": return "网页数据"
        case "Library/Logs": return "日志"
        default: return rel
        }
    }

    // MARK: - 统计

    private struct Tally {
        var bytes: Int64 = 0
        var files: Int = 0
        var nodes: Int = 0
        var denied = false
        var truncated = false
    }

    private func measure(_ target: CacheTarget, group: String?, budget: inout Int) -> CacheTarget {
        var updated = target

        // 没有 App Group 就没有扩展，容器里的东西一个都碰不到
        if target.needsEscape && group == nil {
            updated.state = .denied
            updated.isSelected = false
            return updated
        }

        var tally = Tally()
        var present = false

        for root in target.paths {
            // 先拿到根目录的读权限：没有扩展时连 lstat 都可能是假的
            if let group {
                _ = try? SandboxEscape.grant(path: root, group: group)
            }
            guard SandboxEscape.exists(root) else { continue }
            present = true
            walk(root, group: group, prefix: target.prefixFilter, tally: &tally, depth: 0, budget: &budget)
        }

        updated.bytes = tally.bytes
        updated.files = tally.files

        if !present {
            updated.state = .missing
        } else if tally.bytes == 0 && tally.files == 0 {
            updated.state = tally.denied ? .denied : .empty
        } else {
            updated.state = .ready
        }

        updated.isSelected = updated.recommended && updated.state == .ready
        return updated
    }

    private func walk(
        _ dir: String,
        group: String?,
        prefix: String?,
        tally: inout Tally,
        depth: Int,
        budget: inout Int
    ) {
        guard depth <= Self.maxDepth, budget > 0 else { return }

        var handle = opendir(dir)
        if handle == nil, let group {
            // 父目录的扩展没有覆盖到这里，补签一次
            _ = try? SandboxEscape.grant(path: dir, group: group)
            handle = opendir(dir)
        }
        guard let handle else {
            tally.denied = true
            return
        }
        defer { closedir(handle) }

        while let entry = readdir(handle) {
            let name = CacheCleaner.entryName(entry)
            if name == "." || name == ".." { continue }

            budget -= 1
            tally.nodes += 1
            if budget <= 0 {
                tally.truncated = true
                return
            }

            // 前缀过滤只对顶层生效，进去之后全算
            if depth == 0, let prefix, !name.hasPrefix(prefix) { continue }

            let path = dir + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }

            if (info.st_mode & S_IFMT) == S_IFDIR {
                walk(path, group: group, prefix: nil, tally: &tally, depth: depth + 1, budget: &budget)
            } else {
                // 符号链接也只算自己那一份，不跟进去
                tally.bytes += Int64(info.st_blocks) * 512
                tally.files += 1
            }
        }
    }

    // MARK: - 清理

    struct Report: Sendable {
        var bytes: Int64 = 0
        var files: Int = 0
        var directories: Int = 0
        var cleanedIDs: Set<String> = []
        var failures: [String] = []
        var skipped: Int = 0
        var elapsed: TimeInterval = 0

        var text: String {
            if bytes == 0 && files == 0 && failures.isEmpty {
                return "没有需要清理的内容。"
            }
            var line = "已释放 \(CacheFormat.size(bytes))，清理 \(files) 个文件"
            if !failures.isEmpty {
                line += "（\(failures.count) 处未能删除）"
            }
            return line
        }
    }

    /// 执行清理。`targets` 必须来自 `scan` 的结果——里面带着白名单拼出来的路径。
    func clean(
        _ targets: [CacheTarget],
        group: String?,
        progress: @escaping (Double) -> Void
    ) -> Report {
        var report = Report()
        let started = Date()

        let needsEscape = targets.contains { $0.needsEscape }
        if needsEscape, let group {
            SandboxEscape.beginBatch(group: group)
        }
        defer {
            if needsEscape, group != nil {
                SandboxEscape.endBatch()
            }
        }

        let total = max(1, targets.count)
        for (index, target) in targets.enumerated() {
            let failuresBefore = report.failures.count

            for root in target.paths {
                guard SandboxEscape.exists(root) else { continue }
                guard isSafeForRemoval(root, needsEscape: target.needsEscape) else {
                    report.failures.append("已跳过不受控路径：\(root)")
                    report.skipped += 1
                    continue
                }
                wipe(
                    root,
                    group: target.needsEscape ? group : nil,
                    prefix: target.prefixFilter,
                    depth: 0,
                    report: &report
                )
            }

            if report.failures.count == failuresBefore {
                report.cleanedIDs.insert(target.id)
            }
            progress(Double(index + 1) / Double(total))
        }

        report.elapsed = Date().timeIntervalSince(started)
        return report
    }

    private func wipe(
        _ dir: String,
        group: String?,
        prefix: String?,
        depth: Int,
        report: inout Report
    ) {
        guard depth <= Self.maxDepth else { return }

        // 根目录本身是符号链接时直接放弃：opendir 会跟进去，等于把链接目标删了。
        // （正常情况下白名单路径不可能是链接，这里是最后一道保险）
        if depth == 0 {
            var rootInfo = stat()
            if lstat(dir, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFLNK {
                report.failures.append("拒绝清理符号链接：\(dir)")
                return
            }
        }

        // 删子项要求「父目录」可写。签发一次覆盖整棵子树，失败时再补。
        if let group {
            _ = try? SandboxEscape.grant(path: dir, group: group, requireWrite: true)
        }

        // 先收名字再删：边读边删会让 readdir 跳过条目
        var names: [String] = []
        guard let handle = opendir(dir) else {
            report.failures.append("无法列出：\(dir)")
            return
        }
        while let entry = readdir(handle) {
            let name = CacheCleaner.entryName(entry)
            if name == "." || name == ".." { continue }
            if depth == 0, let prefix, !name.hasPrefix(prefix) { continue }
            names.append(name)
        }
        closedir(handle)

        for name in names {
            let path = dir + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT

            if kind == S_IFDIR {
                // 非空目录要先清空自己，才能从父目录里摘掉
                wipe(path, group: group, prefix: nil, depth: depth + 1, report: &report)
                if rmdir(path) != 0 {
                    if let group {
                        _ = try? SandboxEscape.grant(path: dir, group: group, requireWrite: true)
                    }
                    if rmdir(path) != 0 {
                        report.failures.append("目录删不掉：\(path)")
                        continue
                    }
                }
                report.directories += 1
            } else {
                // 普通文件与符号链接都走 unlink：链接绝不能跟进去
                if unlink(path) != 0 {
                    if let group {
                        _ = try? SandboxEscape.grant(path: dir, group: group, requireWrite: true)
                    }
                    if unlink(path) != 0 {
                        report.failures.append("文件删不掉：\(path)")
                        continue
                    }
                }
                report.files += 1
                report.bytes += Int64(info.st_blocks) * 512
            }
        }
    }

    // MARK: - 护栏

    /// 容器根形如 /private/var/mobile/Containers/Data/Application/<UUID>
    private func isValidContainer(_ path: String) -> Bool {
        let canonical = SandboxEscape.canonicalPath(path)
        let marker = "/private/var/mobile/Containers/Data/"
        guard canonical.hasPrefix(marker) else { return false }
        let parts = canonical.dropFirst(marker.count).split(separator: "/")
        guard parts.count == 2 else { return false }
        let family = String(parts[0])
        guard ["Application", "PluginKitPlugin", "InternalDaemon"].contains(family) else { return false }
        // UUID 之类的目录名，别放过太短的可疑路径
        return parts[1].count >= 8
    }

    /// 删除前的最后一道检查。白名单拼接已经足够，这里只是防「路径被外部改坏」。
    private func isSafeForRemoval(_ path: String, needsEscape: Bool) -> Bool {
        let canonical = SandboxEscape.canonicalPath(path)
        guard canonical.hasPrefix("/"), canonical.count > 1 else { return false }

        if needsEscape {
            // 系统级：只认固定白名单，精确相等或在其之下
            for allowed in Self.systemAllowlist where canonical == allowed || canonical.hasPrefix(allowed + "/") {
                return true
            }

            let marker = "/private/var/mobile/Containers/Data/"
            guard canonical.hasPrefix(marker) else { return false }
            // 必须在 <family>/<UUID>/… 之下，至少再深一层
            let parts = canonical.dropFirst(marker.count).split(separator: "/")
            guard parts.count >= 3 else { return false }
            return true
        }

        let home = SandboxEscape.canonicalPath(NSHomeDirectory())
        let temp = SandboxEscape.canonicalPath(NSTemporaryDirectory())
        return canonical.hasPrefix(home) || canonical.hasPrefix(temp)
    }

    // MARK: - 工具

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        var raw = entry.pointee.d_name
        return withUnsafePointer(to: &raw) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { name in
                String(cString: name)
            }
        }
    }
}
