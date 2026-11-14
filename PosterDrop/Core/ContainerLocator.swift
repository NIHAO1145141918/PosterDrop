//
//  ContainerLocator.swift
//  PosterDrop
//
//  只用 worse_query，定位 PosterBoard 的数据容器。
//
//  能用的入口只有三类：
//    ① 手动填写的路径（用户从 WQFiles 抄来）——最可靠，先验证；
//    ② LaunchServices / containermanagerd 自己的映射（对系统 App 常常为空，但很便宜）；
//    ③ fsgetpath 把 inode 反查成路径——不需要 VPN、不需要列目录权限，
//       代价是要扫一遍卷上的 object id（多线程，几秒），结果会缓存到下次。
//
//  /var/mobile/Containers/Data/Application 这个父目录本身列不出来（WQFiles 的注释也确认了：
//  “The three container parents that can only be listed by scanning”），所以不要把时间花在它身上。
//
//  容器归属靠 xattr `com.apple.containermanager.identifier` 认领；读不到时退一步看
//  Library/Application Support/PRBPosterExtensionDataStore 是否存在。
//
//  速度：
//  - 上次成功的路径排在最前面，自检第二次起基本是 0.1 秒级；
//  - 认领几百个候选时用批量签发，只装一次 Caches 符号链接；
//  - 扫描循环只做 memcmp + strchr，不构造字符串。
//

import Foundation
import Darwin
import ObjectiveC

enum ContainerLocator {

    static let posterBoardBundleID = "com.apple.PosterBoard"
    private static let storeRelativePath = "Library/Application Support/PRBPosterExtensionDataStore"

    /// 所有 App 容器的父目录。一次扩展就能覆盖整棵子树，是批量操作的关键入口。
    static let applicationRoot = "/private/var/mobile/Containers/Data/Application"

    static var applicationRootPath: String { applicationRoot }
    private static let pluginRoot = "/private/var/mobile/Containers/Data/PluginKitPlugin"
    private static let daemonRoot = "/private/var/mobile/Containers/Data/InternalDaemon"

    struct Hit {
        let path: String
        let source: String
    }

    // MARK: - 对外入口

    static func findPosterBoard(group: String, manual: String?, log: @escaping (String) -> Void) -> Hit? {
        find(bundleID: posterBoardBundleID, group: group, manual: manual, log: log)
    }

    /// 同一个扫描结果可以认领任意 App 的容器（dual inject 用）。
    /// - Parameter deepScan: 为 false 时只走「缓存 / LaunchServices / 枚举 / 按 id 查询」这些快路径，
    ///   不触发 fsgetpath 全盘扫描。dual inject 这类「找不到就算了」的场景用它，避免一次几十秒。
    static func find(
        bundleID: String,
        group: String,
        manual: String?,
        deepScan: Bool = true,
        log: @escaping (String) -> Void
    ) -> Hit? {
        let started = Date()
        func stamp(_ text: String) -> String {
            String(format: "%5.2fs  %@", Date().timeIntervalSince(started), text)
        }
        func done(_ hit: Hit) -> Hit {
            log(stamp("✅ 用时 \(String(format: "%.2f", Date().timeIntervalSince(started))) 秒"))
            return hit
        }

        // ⓪ 上次成功的路径：一次 xattr + 一次 stat，最快的一条路
        if let remembered = rememberedPath(for: bundleID), !remembered.isEmpty {
            log(stamp("⓪ 上次定位到的路径：\(remembered)"))
            if verify(path: remembered, group: group, target: bundleID, log: { log(stamp($0)) }) {
                return done(Hit(path: SandboxEscape.canonicalPath(remembered), source: "上次定位"))
            }
            log(stamp("   已失效，从头查找"))
        }

        let manualPath = (manual ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !manualPath.isEmpty, manualPath != rememberedPath(for: bundleID) {
            log(stamp("① 手动路径：\(manualPath)"))
            if verify(path: manualPath, group: group, target: bundleID, log: { log(stamp($0)) }) {
                noteHit(manualPath, bundleID: bundleID)
                return done(Hit(path: SandboxEscape.canonicalPath(manualPath), source: "手动填写"))
            }
            log(stamp("   这个路径不可用，继续自动查找"))
        }

        // 签发通道被内核拒绝时记下错误码。-6 表示 worse_query 已被系统修补，
        // 后面所有路径都依赖同一条通道，继续跑只会让人等——尤其是 ⑤ 的全盘扫描。
        var kernelCode: Int64?

        // ①.5 LaunchServices 直取：一次 ObjC 消息换一个路径，不需要签发也不需要枚举。
        // 系统裁剪 dataContainerURL 时返回 nil，代价只有几微秒；命中时后面几条路全部跳过。
        log(stamp("①.5 LaunchServices 按 bundleID 直取…"))
        if let direct = LaunchServices.containerPath(for: bundleID) {
            log(stamp("   返回容器路径：\(direct)"))
            let check = verifyDetailed(path: direct, group: group, target: bundleID, log: { log(stamp($0)) })
            if check.ok {
                noteHit(direct, bundleID: bundleID)
                return done(Hit(path: SandboxEscape.canonicalPath(direct), source: "LaunchServices 直取"))
            }
            if let code = check.code { kernelCode = code }
            log(stamp("   路径拿到了但进不去，继续按原顺序查找"))
        } else {
            log(stamp("   没有返回容器路径（为空，或返回的不是容器目录），继续查找"))
        }

        // ①.6 签发容器父目录：一次扩展覆盖所有 App 容器，之后逐个读 xattr 就能认领。
        // 成功时整条定位是毫秒级；系统不允许就退回下面几条路，代价只有一次失败尝试。
        log(stamp("①.6 尝试签发容器父目录…"))
        let parent = scanParentDirectory(group: group, target: bundleID, log: { log(stamp($0)) })
        if let hit = parent.hit {
            return done(hit)
        }
        if let code = parent.code { kernelCode = code }

        // 父目录签发失败在 27.x 上是**预期行为**，不能当成「通道死了」。
        // 官方 worse_query 的注释写得很清楚：27.x 上只有 AppGroup 和 System 能拿父目录扩展，
        // Data/Application 不在其中；README 列的访问范围也写成 `Data/Application/*`（子项）。
        // 具体容器是能单独签的，⑤ 的 fsgetpath 枚举就是为这条路准备的——之前在这里
        // 直接 return，等于把唯一可用的那条路自己关上了。
        if let code = kernelCode, code == -6 {
            log(stamp("   父目录扩展被拒（-6）是 27.x 的常态，改走「先枚举具体容器、再逐个签发」"))
        }

        log(stamp("② LaunchServices 映射…"))
        let services = launchServicesContainers()
        log(stamp("   返回 \(services.count) 条带 DataContainer 的记录"))
        for item in services where matches(item.identifier, target: bundleID) {
            log(stamp("   命中 \(item.identifier)：\(item.path)"))
            if verify(path: item.path, group: group, target: bundleID, log: { log(stamp($0)) }) {
                noteHit(item.path, bundleID: bundleID)
                return done(Hit(path: SandboxEscape.canonicalPath(item.path), source: "LaunchServices"))
            }
        }

        log(stamp("③ containermanagerd 枚举…"))
        let enumerated = enumerateContainers()
        log(stamp("   可见容器 \(enumerated.count) 个"))
        for item in enumerated where matches(item.identifier, target: bundleID) {
            log(stamp("   命中 \(item.identifier)：\(item.path)"))
            if verify(path: item.path, group: group, target: bundleID, log: { log(stamp($0)) }) {
                noteHit(item.path, bundleID: bundleID)
                return done(Hit(path: SandboxEscape.canonicalPath(item.path), source: "容器枚举"))
            }
        }

        log(stamp("④ 按 bundle id 直接查询…"))
        if let path = queryByIdentifier(bundleID: bundleID), verify(path: path, group: group, target: bundleID, log: { log(stamp($0)) }) {
            noteHit(path, bundleID: bundleID)
            return done(Hit(path: SandboxEscape.canonicalPath(path), source: "bundle id 查询"))
        }

        guard deepScan else {
            log(stamp("⏭ 只做快路径，跳过全盘扫描（\(bundleID)）"))
            return nil
        }

        log(stamp("⑤ fsgetpath 反查容器 inode（第一次要扫一遍卷，之后走增量）…"))
        let known = loadScanCache()
        if !known.isEmpty {
            log(stamp("   使用上次扫描缓存（\(known.count) 个容器），逐个确认…"))
            if let hit = identify(paths: known, group: group, target: bundleID, log: { log(stamp($0)) }, source: "扫描缓存") {
                return done(hit)
            }
            log(stamp("   缓存里没有，重新扫描"))
        }

        // 已经扫过一遍的话，只需要补扫新增的那一段，分段反而更慢
        if let cached = cachedScanLimit(), cached > 0 {
            let leaked = scanApplicationContainers(log: { log(stamp($0)) })
            if let hit = identify(paths: leaked, group: group, target: bundleID, log: { log(stamp($0)) }, source: "fsgetpath 增量") {
                return done(hit)
            }
        } else if let ceiling = scanCeiling(), ceiling > 1_000_000 {
            // 首次全扫：按 10% / 30% / 100% 分三段。系统 App 的容器是首次开机初始化时
            // 建的，object id 落在卷的前段；每段扫完先认领一次，命中就不必扫剩下的。
            var scanned: Int64 = 0
            for (index, fraction) in scanStages.enumerated() {
                let boundary = min(ceiling, max(scanned, Int64(Double(ceiling) * fraction)))
                guard boundary > scanned else { continue }
                let stage = scanApplicationContainers(
                    log: { log(stamp($0)) },
                    from: scanned + 1,
                    to: boundary,
                    saveCache: fraction >= 1.0
                )
                scanned = boundary
                let label = fraction >= 1.0 ? "第 \(index + 1) 段" : "前 \(Int(fraction * 100))%"
                if let hit = identify(
                    paths: stage, group: group, target: bundleID,
                    log: { log(stamp($0)) }, source: "fsgetpath 枚举 · \(label)"
                ) {
                    return done(hit)
                }
                if fraction < 1.0 {
                    log(stamp("   \(label) 里没有，继续扫…"))
                }
            }
        } else {
            let leaked = scanApplicationContainers(log: { log(stamp($0)) })
            if let hit = identify(paths: leaked, group: group, target: bundleID, log: { log(stamp($0)) }, source: "fsgetpath 枚举") {
                return done(hit)
            }
        }

        // ⑥ 兜底：再试一次父目录（①.6 失败后可能刚好过了一次数据保护解锁）
        if let hit = scanParentDirectory(group: group, target: bundleID, log: { log(stamp($0)) }).hit {
            return done(hit)
        }

        log(stamp("❌ 没有找到 \(bundleID) 的容器。"))
        log("   如果上面显示「得到 0 个应用容器」或「fsgetpath 只能解析自己的文件」，说明这个系统版本拦住了扫描；")
        log("   此时用 WQFiles 打开 App Data › PosterBoard，复制容器路径，粘到诊断页的输入框。")
        return nil
    }

    // MARK: - 验证

    static func verify(path: String, group: String, target: String? = nil, log: (String) -> Void) -> Bool {
        verifyDetailed(path: path, group: group, target: target, log: log).ok
    }

    /// 同 `verify`，但把签发失败的错误码带出来。
    ///
    /// -6（内核拒绝签发）是判定「系统已修补 worse_query」的唯一可靠信号：
    /// 拿到它之后，后面的父目录签发、容器枚举、fsgetpath 扫描都走同一条扩展通道，
    /// 继续跑只会更慢，不可能成功。这个码必须能传出去，否则调用方只会看到「失败」。
    static func verifyDetailed(
        path: String,
        group: String,
        target: String? = nil,
        log: (String) -> Void
    ) -> (ok: Bool, code: Int64?) {
        let target = target ?? posterBoardBundleID
        let canonical = SandboxEscape.canonicalPath(path)
        do {
            _ = try SandboxEscape.grant(path: canonical, group: group)
        } catch let failure as SandboxEscape.Failure {
            log("   ⚠️ 申请扩展失败：\(failure.message)（代码 \(failure.code)）")
            return (false, failure.code)
        } catch {
            log("   ⚠️ 申请扩展失败：\(error.localizedDescription)")
            return (false, nil)
        }

        if target == posterBoardBundleID, SandboxEscape.exists(canonical + "/" + storeRelativePath) {
            log("   ✅ 找到 \(storeRelativePath)")
            return (true, nil)
        }

        // 有些系统版本把 store 放在别处；只要 xattr 认得这个容器就接受
        if let identifier = SandboxEscape.containerIdentifier(at: canonical),
           identifier.lowercased() == target.lowercased() {
            log("   ✅ 容器标识为 \(identifier)（数据目录稍后自动创建）")
            return (true, nil)
        }

        if let items = try? FileManager.default.contentsOfDirectory(atPath: canonical + "/Library"), !items.isEmpty {
            log("   ⚠️ 容器可读，但里面没有目标数据目录")
        } else {
            log("   ⚠️ 容器不可读（数据保护未解锁，或不是目标容器）")
        }
        return (false, nil)
    }

    // MARK: - 批量识别

    /// 在一批路径里找目标 App：先读 xattr，读不到就签发一次再读，最后看数据目录。
    /// 整批共用一个 Caches 交换（批量签发），每个候选只改一下符号链接的指向。
    private static func identify(paths: [String], group: String, target: String, log: (String) -> Void, source: String) -> Hit? {
        guard !paths.isEmpty else { return nil }

        let started = Date()
        SandboxEscape.beginBatch(group: group)
        defer { SandboxEscape.endBatch() }

        var identified = 0
        var checked = 0
        var seen = Set<String>()
        // 逐个签发时把失败码收集起来。如果整批都失败，这组计数能直接回答
        // 「是 -6（daemon 拒发 token）还是 -255（沙盒不让 stat）还是 -8（签了打不开）」，
        // 比只看到「可读标识 0 个」有用得多。
        var failures: [Int64: Int] = [:]

        for path in paths {
            guard seen.insert(path).inserted else { continue }
            checked += 1
            if checked % 50 == 0 {
                let cost = String(format: "%.1f", Date().timeIntervalSince(started))
                log("   已检查 \(checked)/\(paths.count)（\(cost) 秒）…")
            }

            var identifier = SandboxEscape.containerIdentifier(at: path)
            if identifier == nil {
                do {
                    _ = try SandboxEscape.grant(path: path, group: group)
                } catch let failure as SandboxEscape.Failure {
                    failures[failure.code, default: 0] += 1
                } catch {
                    failures[-9, default: 0] += 1
                }
                identifier = SandboxEscape.containerIdentifier(at: path)
            }

            if let identifier {
                identified += 1
                guard identifier.lowercased() == target.lowercased() else { continue }
                log("   ✅ 认领到 \(target)：\(path)")
                noteHit(path, bundleID: target)
                return Hit(path: SandboxEscape.canonicalPath(path), source: source)
            }

            // xattr 读不到：退一步看数据目录是不是存在
            if target == posterBoardBundleID, SandboxEscape.exists(path + "/" + storeRelativePath) {
                log("   ✅ 按数据目录命中：\(path)")
                noteHit(path, bundleID: target)
                return Hit(path: SandboxEscape.canonicalPath(path), source: source + " · 目录判定")
            }
        }
        let cost = String(format: "%.1f", Date().timeIntervalSince(started))
        log("   可读标识 \(identified) 个，没有 \(target)（用时 \(cost) 秒）")
        if !failures.isEmpty {
            let summary = failures
                .sorted { $0.value > $1.value }
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: "，")
            log("   签发失败分布：\(summary)")
        }
        return nil
    }

    // MARK: - fsgetpath 扫描

    private typealias FSGetPath = @convention(c) (UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<fsid_t>?, UInt64) -> Int

    private struct ScanProbe {
        let fsid: fsid_t
        let inode: Int64
        let limit: Int64
    }

    private static let scanMargin: Int64 = 100_000
    /// chunk 从 65536 提到 262144：1.2 亿个 object id 下，chunk 数从 1864 降到 466，
    /// 取任务锁和 formUnion 的次数都降到 1/4。单次 fsgetpath 才是大头，这个只是省掉零碎开销。
    private static let chunkSize: Int64 = 262_144

    /// 分段扫描的进度点。系统 App（PosterBoard 就是）的容器在首次开机初始化时创建，
    /// object id 落在卷的前段；每扫完一段就先试着认领，命中就不用扫后面了。
    /// 10% 一段约 30 秒，30% 一段约 90 秒，最后一段扫完剩余部分。
    private static let scanStages: [Double] = [0.10, 0.30, 1.0]

    /// 容器路径的公共前缀 + 三种容器目录名。扫描时用 memcmp 直接比字节。
    private static let containerCommon: [CChar] = Array("/private/var/mobile/Containers/Data/".utf8).map { CChar(bitPattern: $0) }
    private static let containerKinds: [[CChar]] = ["Application", "PluginKitPlugin", "InternalDaemon"]
        .map { Array($0.utf8).map { CChar(bitPattern: $0) } }

    /// 在临时文件所在的卷上取一个“当前最大 inode”。APFS 的 object id 单调递增，
    /// 比它更大的 id 还不存在，所以可以直接当作扫描上界。
    private static func makeProbe() -> ScanProbe? {
        let candidates = [
            FileManager.default.temporaryDirectory,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ].compactMap { $0 }

        for directory in candidates {
            let probe = directory.appendingPathComponent(".pd-inode-\(UUID().uuidString)")
            let fd = open(probe.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard fd >= 0 else { continue }

            var info = stat()
            var filesystem = statfs()
            let ok = fstat(fd, &info) == 0 && fstatfs(fd, &filesystem) == 0
            close(fd)
            unlink(probe.path)
            guard ok, info.st_ino > 0 else { continue }

            // 临时文件与 App 容器在同一个 Data 卷上，fstatfs 的 fsid 就是扫描要用的 fsid。
            return ScanProbe(fsid: filesystem.f_fsid, inode: Int64(info.st_ino), limit: Int64(info.st_ino) + scanMargin)
        }
        return nil
    }

    /// 当前卷的 object id 上界。分段扫描要先知道总长度，才能按比例切片。
    private static func scanCeiling() -> Int64? {
        makeProbe()?.limit
    }

    /// 扫卷上的 object id，把落在 App 容器目录下的路径反查出来。
    ///
    /// - Parameters:
    ///   - first: 起始 id。传 nil 时按增量策略（上次扫到哪就从哪附近继续）。
    ///   - upper: 结束 id。传 nil 时扫到探针给出的上界。
    ///   - saveCache: 只有扫到上界（或者调用方明确要）才写缓存，分段扫描的中间结果不写，
    ///     否则下次增量会以为整卷都扫完了。
    private static func scanApplicationContainers(
        log: @escaping (String) -> Void,
        from explicitFirst: Int64? = nil,
        to explicitUpper: Int64? = nil,
        saveCache: Bool = false
    ) -> [String] {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fsgetpath") else {
            log("   ⚠️ 系统没有 fsgetpath")
            return []
        }
        let fsgetpath = unsafeBitCast(pointer, to: FSGetPath.self)

        guard let probe = makeProbe() else {
            log("   ⚠️ 无法在 Data 卷上创建探针文件")
            return []
        }

        // 先抽样，确认 fsgetpath 能看到别的 App；看不到就别白扫几百万次
        guard sampleSeesOthers(fsgetpath: fsgetpath, probe: probe) else {
            log("   ⚠️ fsgetpath 只能解析本 App 自己的文件，这个系统版本拦住了路径反查")
            return []
        }

        let upper = min(probe.limit, explicitUpper ?? probe.limit)

        // 增量：上次扫到哪，就从那附近继续
        var first = explicitFirst ?? 1
        if explicitFirst == nil, let cached = cachedScanLimit(), cached > 0, cached < upper {
            first = max(1, cached - scanMargin)
            log("   增量扫描 \(first)…\(upper)（上次扫到 \(cached)）")
        } else if explicitFirst != nil {
            log("   扫描 \(first)…\(upper)")
        } else {
            log("   全量扫描 1…\(upper)")
        }

        let total = max(0, upper - first + 1)
        let chunks = (total + chunkSize - 1) / chunkSize
        guard chunks > 0 else { return [] }

        var nextChunk: Int64 = 0
        var hits = Set<String>()
        let lock = NSLock()
        // fsgetpath 是阻塞 syscall，时间几乎全花在内核的 vnode 查找上（无效 id 也一样贵），
        // 所以超订线程是划算的：8 → 32，实测能把 6 核机器上的 I/O 等待压下去。
        let workers = max(8, min(32, ProcessInfo.processInfo.activeProcessorCount * 4))
        let started = Date()

        let progressQueue = DispatchQueue(label: "posterdrop.scan.progress")
        let progressStep = max(1, chunks / 10)

        // 公共前缀表：一次拼好，所有线程共用（只读）。
        var table = containerCommon
        let commonCount = containerCommon.count
        var kinds: [(offset: Int, count: Int)] = []
        for kind in containerKinds {
            kinds.append((table.count, kind.count))
            table += kind
        }

        table.withUnsafeBufferPointer { sharedPrefix in
            guard let prefix = sharedPrefix.baseAddress else { return }

            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                var local: [String] = []
                var id = probe.fsid
                var buffer = [CChar](repeating: 0, count: 1200)

                buffer.withUnsafeMutableBufferPointer { raw in
                    guard let base = raw.baseAddress else { return }

                    while true {
                        lock.lock()
                        let chunk = nextChunk
                        nextChunk += 1
                        lock.unlock()
                        if chunk >= chunks { break }

                        let chunkStart = first + chunk * chunkSize
                        let chunkEnd = min(chunkStart + chunkSize - 1, upper)

                        var inode = chunkStart
                        while inode <= chunkEnd {
                            let length = fsgetpath(base, raw.count, &id, UInt64(inode))
                            inode += 1
                            guard length > commonCount else { continue }
                            // 先用最长公共前缀一次 memcmp 掉绝大多数结果
                            guard memcmp(base, prefix, commonCount) == 0 else { continue }

                            var matched = false
                            for kind in kinds {
                                guard length > kind.offset + kind.count else { continue }
                                guard memcmp(base + kind.offset, prefix + kind.offset, kind.count) == 0 else { continue }
                                // 容器根目录：名字后面紧跟 '/'，且后面不再有 '/'（排除容器内部的文件）
                                guard base[kind.offset + kind.count] == CChar(UInt8(ascii: "/")) else { break }
                                matched = strchr(base + kind.offset + kind.count + 1, Int32(UInt8(ascii: "/"))) == nil
                                break
                            }
                            if matched {
                                local.append(String(cString: base))
                            }
                        }

                        if !local.isEmpty {
                            lock.lock()
                            hits.formUnion(local)
                            lock.unlock()
                            local.removeAll(keepingCapacity: true)
                        }

                        if chunk % progressStep == 0 {
                            let percent = Int(Double(chunk) / Double(chunks) * 100)
                            progressQueue.async { log("   扫描中 \(percent)%…") }
                        }
                    }
                }
            }
        }

        let cost = String(format: "%.1f", Date().timeIntervalSince(started))
        log("   扫了 \(total) 个 object id，用时 \(cost) 秒，得到 \(hits.count) 个容器（\(workers) 线程）")
        // 增量扫描只覆盖新 id，保存时要把旧缓存合并进来
        let previous = (UserDefaults.standard.array(forKey: ScanCache.paths) as? [String]) ?? []
        let merged = Array(Set(previous + Array(hits)))
        // 分段扫描的中间结果不落盘：只有扫到上界时写的 limit 才是可信的「已扫完」
        if saveCache || upper >= probe.limit {
            saveScanCache(merged, limit: upper)
        }
        return Array(hits)
    }

    /// 抽样 2000 个 id，看解析出来的路径里有没有别的 App 容器。
    private static func sampleSeesOthers(fsgetpath: @escaping FSGetPath, probe: ScanProbe) -> Bool {
        var id = probe.fsid
        var buffer = [CChar](repeating: 0, count: 1200)
        var ownPrefix = FileManager.default.temporaryDirectory.path
        if ownPrefix.hasPrefix("/var/") { ownPrefix = "/private" + ownPrefix }
        ownPrefix = (ownPrefix as NSString).deletingLastPathComponent

        var found = 0
        var resolved = 0
        let samples = 600
        // 在整个 id 区间均匀抽样：老 App 的容器 id 可能远低于上界，只抽上半段会漏判
        let lower: Int64 = 1

        buffer.withUnsafeMutableBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            for _ in 0..<samples {
                let candidate = UInt64.random(in: UInt64(lower)...UInt64(max(lower, probe.limit)))
                let length = fsgetpath(base, raw.count, &id, candidate)
                guard length > 0 else { continue }
                resolved += 1
                let path = String(cString: base)
                if path.contains("/Containers/") && !path.hasPrefix(ownPrefix) {
                    found += 1
                }
            }
        }
        // 一个都解析不到也算“看不到”
        return found > 0 || resolved == 0
    }

    // MARK: - 扫描缓存

    private enum ScanCache {
        static let paths = "posterdrop.scan.paths"
        static let limit = "posterdrop.scan.limit"
        static let date = "posterdrop.scan.date"
        static func located(_ bundleID: String) -> String { "posterdrop.located.\(bundleID)" }
    }

    /// 上一次确认可用的容器路径，下次自检/注入直接用。
    private static func rememberedPath(for bundleID: String) -> String? {
        UserDefaults.standard.string(forKey: ScanCache.located(bundleID))
    }

    /// 给清理页用：某个 App 上次定位到的容器路径（没有就返回 nil）。
    static func rememberedContainerPath(for bundleID: String) -> String? {
        rememberedPath(for: bundleID)
    }

    /// 给清理页用：拿一批已知的容器路径。
    /// 优先复用 fsgetpath 的扫描缓存（清理不该再花几十秒扫一遍卷）；
    /// 缓存为空时才现场扫，扫完照常写回缓存。
    static func discoverContainers(log: @escaping (String) -> Void) -> [String] {
        let cached = loadScanCache()
        if !cached.isEmpty {
            log("复用上次的扫描结果：\(cached.count) 个容器")
            return cached
        }
        log("没有扫描缓存，正在反查容器 inode（第一次会慢几秒）…")
        let fresh = scanApplicationContainers(log: log)
        log("得到 \(fresh.count) 个容器")
        return fresh
    }

    private static func noteHit(_ path: String, bundleID: String) {
        cacheHit(path)
        UserDefaults.standard.set(SandboxEscape.canonicalPath(path), forKey: ScanCache.located(bundleID))
    }

    private static func loadScanCache() -> [String] {
        let defaults = UserDefaults.standard
        guard let date = defaults.object(forKey: ScanCache.date) as? Date,
              Date().timeIntervalSince(date) < 7 * 24 * 3600,
              let paths = defaults.array(forKey: ScanCache.paths) as? [String]
        else { return [] }
        // 这里不能拿 fileExists 过滤：容器路径在沙箱外本来就 stat 不到，
        // 过滤会把整份缓存清空，下次又得全盘 fsgetpath 扫一遍（几十秒）。
        // 失效的路径留给调用方判断，反正它们签不出扩展。
        return paths
    }

    private static func cachedScanLimit() -> Int64? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: ScanCache.date) != nil else { return nil }
        return (defaults.object(forKey: ScanCache.limit) as? NSNumber)?.int64Value
    }

    private static func saveScanCache(_ paths: [String], limit: Int64) {
        let defaults = UserDefaults.standard
        defaults.set(paths, forKey: ScanCache.paths)
        defaults.set(limit, forKey: ScanCache.limit)
        defaults.set(Date(), forKey: ScanCache.date)
    }

    /// 自检/手动填对之后也记一笔，下次直接命中。
    private static func cacheHit(_ path: String) {
        let canonical = SandboxEscape.canonicalPath(path)
        var paths = (UserDefaults.standard.array(forKey: ScanCache.paths) as? [String]) ?? []
        if !paths.contains(canonical) {
            paths.insert(canonical, at: 0)
            UserDefaults.standard.set(Array(paths.prefix(400)), forKey: ScanCache.paths)
        }
        UserDefaults.standard.set(Date(), forKey: ScanCache.date)
    }

    // MARK: - containermanagerd

    private struct Entry {
        let path: String
        let identifier: String
    }

    private typealias QueryCreate = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias QuerySetClass = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetIDs = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias QuerySetBool = @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void
    private typealias QueryFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias QueryIterate = @convention(c) (UnsafeMutableRawPointer?, @convention(block) (UnsafeMutableRawPointer?) -> Bool) -> Void
    private typealias ObjectGetPath = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
    private typealias ObjectGetIdentifier = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?

    private static func enumerateContainers() -> [Entry] {
        guard let manager = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL) else {
            return []
        }
        defer { dlclose(manager) }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(manager, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard let create = symbol("container_query_create", as: QueryCreate.self),
              let setClass = symbol("container_query_set_class", as: QuerySetClass.self),
              let iterate = symbol("container_query_iterate_results_sync", as: QueryIterate.self),
              let freeQuery = symbol("container_query_free", as: QueryFree.self),
              let getPath = symbol("container_object_get_path", as: ObjectGetPath.self)
        else { return [] }

        let setOtherOwners = symbol("container_query_set_include_other_owners", as: QuerySetBool.self)
        let getIdentifier = symbol("container_object_get_identifier", as: ObjectGetIdentifier.self)
            ?? symbol("container_result_get_identifier", as: ObjectGetIdentifier.self)

        var results: [Entry] = []
        var seen = Set<String>()

        // WQFiles 用的这组 class；0 是全局，2 是 App，5/10 是扩展/插件
        for cls in [UInt64(0), 2, 5, 7, 8, 10, 11, 13] {
            guard let query = create() else { continue }
            setClass(query, cls)
            setOtherOwners?(query, true)
            iterate(query, { object in
                guard let object, let pathPointer = getPath(object) else { return true }
                let path = String(cString: pathPointer)
                guard !path.isEmpty else { return true }

                let identifier: String
                if let getIdentifier, let idPointer = getIdentifier(object) {
                    identifier = String(cString: idPointer)
                } else {
                    identifier = ""
                }

                let key = path + "|" + identifier
                if seen.insert(key).inserted {
                    results.append(Entry(path: path, identifier: identifier))
                }
                return true
            })
            freeQuery(query)
        }
        return results
    }

    private static func matches(_ identifier: String, target: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let lower = identifier.lowercased()
        let wanted = target.lowercased()
        return lower == wanted || lower.hasSuffix("." + wanted)
    }

    // MARK: - 父目录（一次覆盖所有 App 容器）

    /// 签发容器父目录并常驻：一次扩展覆盖所有 App 容器，之后遍历、读 xattr 都不再逐个签发。
    /// 这是把「几百次 XPC」压成「一次 XPC」的关键。
    ///
    /// - Parameter requireWrite: 清理时传 true。父目录只读能扫不能删，所以先试可写；
    ///   写探针失败（系统把父目录设成只读）时退回只读，至少扫描还能走快路径。
    @discardableResult
    static func grantApplicationRoot(group: String, requireWrite: Bool = false) -> Bool {
        grantApplicationRootDetailed(group: group, requireWrite: requireWrite).ok
    }

    /// 和 `grantApplicationRoot` 一样，但把失败原因带出来。
    ///
    /// 这条路的成败决定了扫描能不能走快路径，失败时如果只说「失败」，
    /// 就分不清是 containermanagerd 拒绝了 Caches 指向父目录，还是写探针没通过。
    static func grantApplicationRootDetailed(
        group: String,
        requireWrite: Bool = false
    ) -> (ok: Bool, code: Int64?, detail: String) {
        var reasons: [String] = []
        var lastCode: Int64?

        if requireWrite {
            do {
                _ = try SandboxEscape.grant(
                    path: applicationRoot, group: group, requireWrite: true, pinned: true
                )
                return (true, nil, "可写")
            } catch let failure as SandboxEscape.Failure {
                lastCode = failure.code
                reasons.append("可写：\(failure.localizedDescription)")
            } catch {
                reasons.append("可写：\(error.localizedDescription)")
            }
        }

        do {
            _ = try SandboxEscape.grant(path: applicationRoot, group: group, pinned: true)
            return (true, nil, requireWrite ? "只读（写探针失败：\(reasons.joined(separator: "；"))）" : "只读")
        } catch let failure as SandboxEscape.Failure {
            lastCode = failure.code
            reasons.append("只读：\(failure.localizedDescription)")
        } catch {
            reasons.append("只读：\(error.localizedDescription)")
        }

        return (false, lastCode, reasons.joined(separator: "；"))
    }

    private static func scanParentDirectory(
        group: String,
        target: String,
        log: (String) -> Void
    ) -> (hit: Hit?, code: Int64?) {
        do {
            _ = try SandboxEscape.grant(path: applicationRoot, group: group, pinned: true)
        } catch let failure as SandboxEscape.Failure {
            log("   父目录扩展签不出来：\(failure.message)（代码 \(failure.code)）")
            return (nil, failure.code)
        } catch {
            log("   父目录扩展签不出来：\(error.localizedDescription)")
            return (nil, nil)
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: applicationRoot) else {
            log("   父目录不可枚举（系统限制），需要手动填路径")
            return (nil, nil)
        }
        log("   枚举到 \(entries.count) 个应用容器，按容器标识匹配…")

        // 快路径：父目录扩展覆盖整棵树，读 xattr 是微秒级，600 个容器也就几毫秒。
        // 先按标识认领，不命中再退回完整校验（那条会列举目录，慢一个量级）。
        for name in entries.prefix(600) {
            let path = applicationRoot + "/" + name
            guard let identifier = SandboxEscape.containerIdentifier(at: path),
                  identifier.lowercased() == target.lowercased()
            else { continue }
            noteHit(path, bundleID: target)
            log("   命中 \(identifier)：\(path)")
            return (Hit(path: path, source: "容器列举"), nil)
        }

        log("   没有容器标识匹配，逐个校验…")
        for name in entries.prefix(200) {
            let path = applicationRoot + "/" + name
            if verify(path: path, group: group, target: target, log: { _ in }) {
                noteHit(path, bundleID: target)
                return (Hit(path: path, source: "容器列举"), nil)
            }
        }
        return (nil, nil)
    }

    // MARK: - LaunchServices

    private typealias MsgSend = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias MsgSendObject = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?

    private static func send(_ target: AnyObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector),
              let method = class_getInstanceMethod(type(of: target), selector) else { return nil }
        let send = unsafeBitCast(method_getImplementation(method), to: MsgSend.self)
        return send(target, selector)?.takeUnretainedValue()
    }

    private static func sendClass(_ cls: AnyClass, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        let send = unsafeBitCast(method_getImplementation(method), to: MsgSend.self)
        return send(cls as AnyObject, selector)?.takeUnretainedValue()
    }

    private static func sendObject(_ target: AnyObject, _ name: String, _ argument: AnyObject) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector),
              let method = class_getInstanceMethod(type(of: target), selector) else { return nil }
        let send = unsafeBitCast(method_getImplementation(method), to: MsgSendObject.self)
        return send(target, selector, argument)?.takeUnretainedValue()
    }

    /// 类方法版本的 sendObject：`class_getClassMethod` 找不到就返回 nil。
    private static func sendClassObject(_ cls: AnyClass, _ name: String, _ argument: AnyObject) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        let send = unsafeBitCast(method_getImplementation(method), to: MsgSendObject.self)
        return send(cls as AnyObject, selector, argument)?.takeUnretainedValue()
    }

    private static func launchServicesContainers() -> [Entry] {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace"),
              let workspace = sendClass(workspaceClass, "defaultWorkspace") else { return [] }

        var results: [Entry] = []
        var seen = Set<String>()

        func append(_ proxy: AnyObject) {
            guard let identifier = send(proxy, "bundleIdentifier") as? String,
                  let url = send(proxy, "dataContainerURL") as? URL,
                  !url.path.isEmpty
            else { return }
            let key = identifier + "|" + url.path
            guard seen.insert(key).inserted else { return }
            results.append(Entry(path: url.path, identifier: identifier))
        }

        for listSelector in ["allApplications", "allInstalledApplications"] {
            guard let list = send(workspace, listSelector) as? [AnyObject] else { continue }
            for app in list {
                append(app)
                if let plugins = send(app, "plugInKitPlugins") as? [AnyObject] {
                    for plugin in plugins { append(plugin) }
                }
            }
        }

        // 这两个选择器属于 LSApplicationProxy 的类方法。发给 workspace 会安静返回 nil，
        // 结果只剩下 allApplications 全表兜底，等于白跑一遍。
        if let proxyClass = NSClassFromString("LSApplicationProxy") {
            for selector in ["applicationProxyForIdentifier:", "applicationProxyForBundleIdentifier:"] {
                if let proxy = sendClassObject(proxyClass, selector, posterBoardBundleID as NSString) {
                    append(proxy)
                }
            }
        }
        return results
    }

    // MARK: - 按 bundle id 查

    private static func queryByIdentifier(bundleID: String) -> String? {
        guard let manager = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        defer { dlclose(manager) }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(manager, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        typealias QueryGetSingle = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        typealias XPCStringCreate = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
        typealias XPCArrayCreate = @convention(c) (UnsafeMutableRawPointer?, Int) -> UnsafeMutableRawPointer?
        typealias XPCArrayAppend = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

        guard let create = symbol("container_query_create", as: QueryCreate.self),
              let setClass = symbol("container_query_set_class", as: QuerySetClass.self),
              let setIdentifiers = symbol("container_query_set_identifiers", as: QuerySetIDs.self),
              let single = symbol("container_query_get_single_result", as: QueryGetSingle.self),
              let freeQuery = symbol("container_query_free", as: QueryFree.self),
              let getPath = symbol("container_object_get_path", as: ObjectGetPath.self),
              let xpcLib = dlopen("/usr/lib/system/libxpc.dylib", RTLD_NOW),
              let xpcPointer = dlsym(xpcLib, "xpc_string_create")
        else { return nil }
        defer { dlclose(xpcLib) }

        let setOtherOwners = symbol("container_query_set_include_other_owners", as: QuerySetBool.self)
        let xpcString = unsafeBitCast(xpcPointer, to: XPCStringCreate.self)

        var arrayCreate: XPCArrayCreate?
        var arrayAppend: XPCArrayAppend?
        if let createPtr = dlsym(xpcLib, "xpc_array_create") {
            arrayCreate = unsafeBitCast(createPtr, to: XPCArrayCreate.self)
        }
        if let appendPtr = dlsym(xpcLib, "xpc_array_append_value") {
            arrayAppend = unsafeBitCast(appendPtr, to: XPCArrayAppend.self)
        }

        var identifierValues: [UnsafeMutableRawPointer?] = [xpcString(bundleID)]

        if let arrayCreate, let arrayAppend, let string = xpcString(bundleID) {
            let array = arrayCreate(nil, 0)
            arrayAppend(array, string)
            identifierValues.append(array)
        }

        for value in identifierValues {
            guard let value else { continue }
            guard let query = create() else { continue }
            defer { freeQuery(query) }

            setClass(query, 2)
            setOtherOwners?(query, true)
            setIdentifiers(query, value)

            if let result = single(query), let pathPointer = getPath(result) {
                let path = String(cString: pathPointer)
                if !path.isEmpty { return path }
            }
        }
        return nil
    }
}
