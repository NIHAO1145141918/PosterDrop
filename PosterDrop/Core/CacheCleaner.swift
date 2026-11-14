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
//    3. 删除只在「已打开的父目录 fd」上做 unlinkat / AT_REMOVEDIR，所有打开都带
//       O_NOFOLLOW，不会被符号链接引到别的容器。
//
//  覆盖范围（按「删了会怎样」分层）：
//    · 可重建：Caches / tmp / SplashBoard / Saved Application State / Logs
//    · 需重登：Cookies / WebKit / HTTPStorages
//    · 系统级：全系统应用快照 / 崩溃日志 / 共享缓存（默认不勾）
//
//  性能（这一版重写了遍历内核）：
//    - 目录只打开一次，之后 openat / fstatat / unlinkat 全部以 fd 为起点，
//      不再拼 /private/var/mobile/Containers/Data/Application/<UUID>/... 这种全路径，
//      每访问一个文件省掉一次从根开始的前缀解析；
//    - 统计走 getattrlistbulk，一次系统调用取回一批条目（名字 + 类型 + 占用）；
//    - 容器父目录签一次并常驻，其余全部是 openat，正常路径不产生 XPC；
//    - 整轮扫描有 20 秒硬截止，到点不再开新容器。
//

import Foundation
import Darwin
import Dispatch

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

    /// 单个目标的遍历预算。改成 fd 相对遍历 + getattrlistbulk 之后，单条成本从
    /// 一次全路径 stat 降到百纳秒级，原来 5 万的预算可以放宽到 30 万而且更快。
    private static let measureBudget = 300_000
    /// 整轮扫描的时间上限。到点就不再开新容器，已经在跑的子树自行收尾。
    /// 30 秒是产品要求，这里留 10 秒给签发、UI 刷新和收尾。
    private static let scanTimeBudget: TimeInterval = 20
    /// 深度扫描最多看多少个容器。父目录扩展可用时基本等于全量。
    private static let otherScanLimit = 400
    /// 父目录扩展签不出来时只能逐个签发（每个约 80–120ms），上限压到 120 才能守住 30 秒。
    private static let otherScanLimitSlow = 120
    /// 列表里最多展示多少个 App（按占用从大到小）。
    private static let otherDisplayLimit = 60

    // MARK: - 扫描

    /// 已经打开的父目录：让 8 个缓存子目录共用一次 open，而不是各自解析全路径。
    private struct BaseDirectory {
        let fd: Int32
        let path: String
    }

    /// 统计所有缓存项。`includeOthers` 为 true 时才会去扫别的 App（慢，几秒）。
    func scan(
        container: String?,
        group: String?,
        includeOthers: Bool,
        log: @escaping (String) -> Void
    ) -> [CacheTarget] {

        // 整轮扫描共用一个截止时间。超时就不再开新目标，已经跑起来的子树自行收尾，
        // 这样「30 秒」是硬上限，而不是取决于设备上有多少个 App。
        let deadline = Date().addingTimeInterval(Self.scanTimeBudget)

        var targets = makeAppTargets()

        let canonicalContainer: String? = {
            guard let container, isValidContainer(container) else { return nil }
            return SandboxEscape.canonicalPath(container)
        }()

        if let canonicalContainer {
            targets += makePosterBoardTargets(container: canonicalContainer)
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

        // PosterBoard 容器根：签一次、开一次。8 个缓存子目录都用这个 fd 做 openat 起点，
        // 省掉 8 次全路径解析（路径里有 UUID，解析起来比看着长）。
        var containerFD: Int32?
        if let canonicalContainer, let group {
            _ = try? SandboxEscape.grant(path: canonicalContainer, group: group)
            containerFD = FileTree.openDirectory(canonicalContainer)
        }
        defer { if let containerFD { close(containerFD) } }

        let base = containerFD.map { BaseDirectory(fd: $0, path: canonicalContainer ?? "") }

        // 这十来个目标彼此独立（都没打开 Caches 交换），并行统计；
        // 系统级三项路径固定、要各自签发，放后面串行更稳。
        var appSlots = [CacheTarget?](repeating: nil, count: targets.count)
        appSlots.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                let target = targets[index]
                buffer[index] = measure(
                    target,
                    group: target.needsEscape ? group : nil,
                    base: base,
                    deadline: deadline
                )
            }
        }
        let measuredApp = appSlots.compactMap { $0 }

        var measured = measuredApp
        if includeOthers, let group {
            measured.append(contentsOf: scanOtherApps(group: group, deadline: deadline, log: log))
        }

        // 系统级三项：不需要容器，路径固定
        measured.append(contentsOf: makeSystemTargets().map {
            measure($0, group: group, base: nil, deadline: deadline)
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
    ///
    /// 两条路：
    ///   · 父目录扩展签出来了（绝大多数情况）——打开一次 Application 目录，
    ///     之后每个容器都是 openat 直接进。不再逐个签发、不再拼全路径，
    ///     所有容器可以一次性铺开并行，这是本轮提速的主要来源。
    ///   · 签不出来——退回逐个签发（每个 80–120ms），上限压到 120 并分批，
    ///     保证不超时。
    private func scanOtherApps(
        group: String,
        deadline: Date,
        log: @escaping (String) -> Void
    ) -> [CacheTarget] {
        let started = Date()

        // 带写权限签父目录：一次探针，换来之后所有容器的打开与删除都不用再补签。
        let rootGranted = ContainerLocator.grantApplicationRoot(group: group, requireWrite: true)
        if rootGranted {
            log("容器父目录已授权（含写权限）：整轮不再逐个签发扩展")
        }

        let posterCanonical = ContainerLocator
            .rememberedContainerPath(for: ContainerLocator.posterBoardBundleID)
            .map { SandboxEscape.canonicalPath($0) }

        if rootGranted, let rootFD = FileTree.openDirectory(ContainerLocator.applicationRootPath) {
            defer { close(rootFD) }
            if let fast = scanContainersFast(
                rootFD: rootFD,
                rootPath: ContainerLocator.applicationRootPath,
                poster: posterCanonical,
                started: started,
                deadline: deadline,
                log: log
            ) {
                return fast
            }
        }

        let containers = ContainerLocator.discoverContainers(log: log)
        guard !containers.isEmpty else {
            log("没有发现其他 App 的容器，跳过")
            return []
        }
        return scanContainersSlow(
            group: group,
            containers: containers,
            poster: posterCanonical,
            started: started,
            deadline: deadline,
            log: log
        )
    }

    // MARK: 快路径

    private func scanContainersFast(
        rootFD: Int32,
        rootPath: String,
        poster: String?,
        started: Date,
        deadline: Date,
        log: @escaping (String) -> Void
    ) -> [CacheTarget]? {
        var names: [String] = []
        let iterator = dup(rootFD)
        if iterator >= 0, let directory = fdopendir(iterator) {
            while let entry = readdir(directory) {
                let name = FileTree.entryName(entry)
                if name == "." || name == ".." { continue }
                names.append(name)
            }
            closedir(directory)
        } else {
            if iterator >= 0 { close(iterator) }
            log("父目录不可枚举（系统限制），退回逐个签发")
            return nil
        }

        guard !names.isEmpty else { return [] }
        let limit = min(names.count, Self.otherScanLimit)

        var slots = [CacheTarget?](repeating: nil, count: limit)
        let skipped = Counter()

        slots.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: limit) { index in
                // 时间到就不再开新容器，已经在跑的自然结束
                if Date() >= deadline {
                    skipped.increment()
                    return
                }

                let name = names[index]
                let path = rootPath + "/" + name
                if let poster, path == poster { return }

                guard let containerFD = FileTree.openSubdirectory(rootFD, name) else { return }
                defer { close(containerFD) }

                buffer[index] = makeOtherTarget(
                    containerFD: containerFD,
                    path: path,
                    deadline: deadline
                )
            }
        }

        let results = slots.compactMap { $0 }
        var reasons: [String] = []
        if names.count > limit { reasons.append("\(names.count - limit) 个超出单次上限") }
        let missed = skipped.value
        if missed > 0 { reasons.append("\(missed) 个超时跳过") }
        let note = reasons.isEmpty ? "" : "（" + reasons.joined(separator: "，") + "）"
        log(String(
            format: "其他 App：%d 个容器，%d 个有缓存，用时 %.1f 秒%@",
            limit,
            results.count,
            Date().timeIntervalSince(started),
            note
        ))
        return results
    }

    // MARK: 慢路径（父目录签不出来）

    private func scanContainersSlow(
        group: String,
        containers: [String],
        poster: String?,
        started: Date,
        deadline: Date,
        log: @escaping (String) -> Void
    ) -> [CacheTarget] {
        var seen = Set<String>()
        var candidates: [String] = []
        for container in containers.prefix(Self.otherScanLimitSlow) {
            let canonical = SandboxEscape.canonicalPath(container)
            if let poster, canonical == poster { continue }
            guard seen.insert(canonical).inserted else { continue }
            candidates.append(canonical)
        }
        guard !candidates.isEmpty else { return [] }

        var results: [CacheTarget] = []
        results.reserveCapacity(candidates.count)
        // 内核能同时挂的扩展有上限（192），一次签完会把前面的挤掉，所以分批
        let batchSize = 24
        var offset = 0

        while offset < candidates.count, Date() < deadline {
            let end = min(offset + batchSize, candidates.count)
            let slice = Array(candidates[offset..<end])
            offset = end

            // 签发必须串行：Caches 交换是全进程唯一的
            var granted: [(path: String, fd: Int32)] = []
            granted.reserveCapacity(slice.count)
            for path in slice {
                guard (try? SandboxEscape.grant(path: path, group: group)) != nil,
                      let fd = FileTree.openDirectory(path) else { continue }
                granted.append((path, fd))
            }

            if !granted.isEmpty {
                var slots = [CacheTarget?](repeating: nil, count: granted.count)
                slots.withUnsafeMutableBufferPointer { buffer in
                    DispatchQueue.concurrentPerform(iterations: granted.count) { index in
                        let item = granted[index]
                        buffer[index] = makeOtherTarget(
                            containerFD: item.fd,
                            path: item.path,
                            deadline: deadline
                        )
                    }
                }
                for item in granted { close(item.fd) }
                results.append(contentsOf: slots.compactMap { $0 })
            }

            log("其他 App：进度 \(offset)/\(candidates.count)")
        }

        log(String(
            format: "其他 App：%d 个容器，%d 个有缓存，用时 %.1f 秒（逐个签发）",
            candidates.count,
            results.count,
            Date().timeIntervalSince(started)
        ))
        return results
    }

    /// 在一个已经打开的容器上统计 8 个白名单目录。
    /// 全部用 openat 相对 containerFD，8 个目录各解析一段短路径。
    private func makeOtherTarget(
        containerFD: Int32,
        path: String,
        deadline: Date
    ) -> CacheTarget? {
        var picked: [String] = []
        for entry in Self.containerEntries where FileTree.exists(containerFD, entry.rel) {
            picked.append(entry.rel)
        }
        guard !picked.isEmpty else { return nil }

        let tally = FileTree.Tally()
        var budget = Self.measureBudget
        for rel in picked {
            guard let child = FileTree.openSubdirectory(containerFD, rel) else { continue }
            FileTree.measure(
                fd: child,
                path: path + "/" + rel,
                prefix: nil,
                budget: &budget,
                deadline: deadline,
                tally: tally
            )
            close(child)
        }
        guard tally.bytes > 0 || tally.files > 0 else { return nil }

        // 相对容器 fd 读标识，不再走一遍全路径 getxattr
        let identifier = FileTree.xattr(containerFD, "com.apple.containermanager.identifier")
        let identifierText = (identifier?.isEmpty == false) ? identifier : nil
        let title = identifierText ?? (path as NSString).lastPathComponent

        return CacheTarget(
            id: "other." + path,
            scope: .other,
            title: title,
            subtitle: identifierText == nil ? (path as NSString).lastPathComponent : nil,
            detail: "\(picked.count) 项：" + picked.map { shortLabel($0) }.joined(separator: "、"),
            paths: picked.map { path + "/" + $0 },
            prefixFilter: nil,
            needsEscape: true,
            recommended: false,
            caution: nil,
            bytes: tally.bytes,
            files: tally.files,
            state: .ready
        )
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

    private func measure(
        _ target: CacheTarget,
        group: String?,
        base: BaseDirectory?,
        deadline: Date
    ) -> CacheTarget {
        var updated = target

        // 没有 App Group 就没有扩展，容器里的东西一个都碰不到
        if target.needsEscape && group == nil {
            updated.state = .denied
            updated.isSelected = false
            return updated
        }

        let tally = FileTree.Tally()
        var present = false
        var used = 0

        for root in target.paths {
            // 父目录 fd 已经打开时走 openat，省一次全路径解析
            var parentFD: Int32?
            var relative: String?
            if let base, root.hasPrefix(base.path + "/") {
                parentFD = base.fd
                relative = String(root.dropFirst(base.path.count + 1))
            }

            // 有父目录 fd 就直接 openat，成功路径不产生任何 XPC。
            // 只有根本拿不到父目录时才先补签，这是少数情况。
            if parentFD == nil, let group {
                _ = try? SandboxEscape.grant(path: root, group: group)
            }

            let before = tally.nodes
            var measured = FileTree.measure(
                root: root,
                parent: parentFD,
                relative: relative,
                prefix: target.prefixFilter,
                budget: max(0, Self.measureBudget - used),
                deadline: deadline,
                tally: tally
            )

            // 父目录扩展可能被内核回收，openat 打不开时补签一次再从来路走一遍
            if !measured, parentFD != nil, let group {
                _ = try? SandboxEscape.grant(path: root, group: group)
                measured = FileTree.measure(
                    root: root,
                    parent: nil,
                    relative: nil,
                    prefix: target.prefixFilter,
                    budget: max(0, Self.measureBudget - used),
                    deadline: deadline,
                    tally: tally
                )
            }

            if measured {
                present = true
                used += tally.nodes - before
            }
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

        // 其他 App 占大头：先拿一次「可写」的父目录扩展。
        // 之后每个容器的删除都是祖先命中，不再逐容器走 XPC，也不用再验写探针。
        let hasOthers = targets.contains { $0.scope == .other }
        if needsEscape, let group, hasOthers {
            _ = ContainerLocator.grantApplicationRoot(group: group, requireWrite: true)
        }

        // 父目录 fd：把 8 个缓存目录的全路径打开换成一次 openat
        var rootFD: Int32?
        if hasOthers {
            rootFD = FileTree.openDirectory(ContainerLocator.applicationRootPath)
        }
        defer { if let rootFD { close(rootFD) } }
        let base = rootFD.map { BaseDirectory(fd: $0, path: ContainerLocator.applicationRootPath) }

        let total = max(1, targets.count)
        for (index, target) in targets.enumerated() {
            let failuresBefore = report.failures.count

            for root in target.paths {
                // 白名单校验在前，任何被改坏的路径都进不到删除逻辑
                guard isSafeForRemoval(root, needsEscape: target.needsEscape) else {
                    report.failures.append("已跳过不受控路径：\(root)")
                    report.skipped += 1
                    continue
                }

                var parentFD: Int32?
                var relative: String?
                if let base, root.hasPrefix(base.path + "/") {
                    parentFD = base.fd
                    relative = String(root.dropFirst(base.path.count + 1))
                }

                // 父目录已覆盖时这里直接 openat，不产生 XPC。
                // 拿不到父目录 fd（慢路径）才先签一次写扩展。
                if parentFD == nil, target.needsEscape, let group {
                    _ = try? SandboxEscape.grant(path: root, group: group, requireWrite: true)
                }

                var removal = FileTree.Removal()
                var opened = FileTree.clear(
                    root: root,
                    prefix: target.prefixFilter,
                    parent: parentFD,
                    relative: relative,
                    removal: &removal
                )

                // 打不开：扩展可能被回收，补签一次从头来
                if !opened, target.needsEscape, let group, parentFD != nil {
                    _ = try? SandboxEscape.grant(path: root, group: group, requireWrite: true)
                    opened = FileTree.clear(
                        root: root,
                        prefix: target.prefixFilter,
                        parent: nil,
                        relative: nil,
                        removal: &removal
                    )
                }
                guard opened else { continue }

                // 能打开却删不动：多半是父目录扩展只有读权限。补一次写扩展，把剩下的再删一遍。
                if !removal.failures.isEmpty, target.needsEscape, let group,
                   (try? SandboxEscape.grant(path: root, group: group, requireWrite: true)) != nil {
                    var retry = FileTree.Removal()
                    _ = FileTree.clear(
                        root: root,
                        prefix: target.prefixFilter,
                        parent: parentFD,
                        relative: relative,
                        removal: &retry
                    )
                    removal.files += retry.files
                    removal.directories += retry.directories
                    removal.bytes += retry.bytes
                    removal.failures = retry.failures
                }

                report.bytes += removal.bytes
                report.files += removal.files
                report.directories += removal.directories
                report.failures.append(contentsOf: removal.failures)
            }

            if report.failures.count == failuresBefore {
                report.cleanedIDs.insert(target.id)
            }
            progress(Double(index + 1) / Double(total))
        }

        report.elapsed = Date().timeIntervalSince(started)
        return report
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

}

/// 并发计数的极简实现：只为「有多少个容器因为超时被跳过」服务。
final class Counter: @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
