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

import Foundation
import Darwin
import ObjectiveC

enum ContainerLocator {

    static let posterBoardBundleID = "com.apple.PosterBoard"
    private static let storeRelativePath = "Library/Application Support/PRBPosterExtensionDataStore"

    private static let applicationRoot = "/private/var/mobile/Containers/Data/Application"
    private static let pluginRoot = "/private/var/mobile/Containers/Data/PluginKitPlugin"
    private static let daemonRoot = "/private/var/mobile/Containers/Data/InternalDaemon"

    struct Hit {
        let path: String
        let source: String
    }

    // MARK: - 对外入口

    static func findPosterBoard(group: String, manual: String?, log: (String) -> Void) -> Hit? {
        find(bundleID: posterBoardBundleID, group: group, manual: manual, log: log)
    }

    /// 同一个扫描结果可以认领任意 App 的容器（dual inject 用）。
    static func find(bundleID: String, group: String, manual: String?, log: (String) -> Void) -> Hit? {
        let manualPath = (manual ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !manualPath.isEmpty {
            log("① 手动路径：\(manualPath)")
            if verify(path: manualPath, group: group, target: bundleID, log: log) {
                cacheHit(manualPath)
                return Hit(path: SandboxEscape.canonicalPath(manualPath), source: "手动填写")
            }
            log("   这个路径不可用，继续自动查找")
        }

        log("② LaunchServices 映射…")
        let services = launchServicesContainers()
        log("   返回 \(services.count) 条带 DataContainer 的记录")
        for item in services where matches(item.identifier) {
            log("   命中 \(item.identifier)：\(item.path)")
            if verify(path: item.path, group: group, target: bundleID, log: log) {
                cacheHit(item.path)
                return Hit(path: SandboxEscape.canonicalPath(item.path), source: "LaunchServices")
            }
        }

        log("③ containermanagerd 枚举…")
        let enumerated = enumerateContainers()
        log("   可见容器 \(enumerated.count) 个")
        for item in enumerated where matches(item.identifier, target: bundleID) {
            log("   命中 \(item.identifier)：\(item.path)")
            if verify(path: item.path, group: group, target: bundleID, log: log) {
                cacheHit(item.path)
                return Hit(path: SandboxEscape.canonicalPath(item.path), source: "容器枚举")
            }
        }

        log("④ 按 bundle id 直接查询…")
        if let path = queryByIdentifier(bundleID: bundleID), verify(path: path, group: group, target: bundleID, log: log) {
            cacheHit(path)
            return Hit(path: SandboxEscape.canonicalPath(path), source: "bundle id 查询")
        }

        log("⑤ fsgetpath 反查容器 inode（不需要 VPN；第一次要扫几秒，之后走缓存）…")
        let known = loadScanCache()
        if !known.isEmpty {
            log("   使用上次扫描缓存（\(known.count) 个容器），逐个确认…")
            if let hit = identify(paths: known, group: group, target: bundleID, log: log, source: "扫描缓存") {
                return hit
            }
            log("   缓存里没有，重新扫描")
        }

        let leaked = scanApplicationContainers(log: log)
        if let hit = identify(paths: leaked, group: group, target: bundleID, log: log, source: "fsgetpath 枚举") {
            return hit
        }

        log("⑥ 尝试直接列举容器父目录…")
        if let hit = scanParentDirectory(group: group, target: bundleID, log: log) {
            return hit
        }

        log("❌ 没有找到 \(bundleID) 的容器。")
        log("   如果上面显示「得到 0 个应用容器」或「fsgetpath 只能解析自己的文件」，说明这个系统版本拦住了扫描；")
        log("   此时用 WQFiles 打开 App Data › PosterBoard，复制容器路径，粘到诊断页的输入框。")
        return nil
    }

    // MARK: - 验证

    static func verify(path: String, group: String, target: String? = nil, log: (String) -> Void) -> Bool {
        let target = target ?? posterBoardBundleID
        let canonical = SandboxEscape.canonicalPath(path)
        do {
            _ = try SandboxEscape.grant(path: canonical, group: group)
        } catch {
            log("   ⚠️ 申请扩展失败：\(error.localizedDescription)")
            return false
        }

        if target == posterBoardBundleID, SandboxEscape.exists(canonical + "/" + storeRelativePath) {
            log("   ✅ 找到 \(storeRelativePath)")
            return true
        }

        // 有些系统版本把 store 放在别处；只要 xattr 认得这个容器就接受
        if let identifier = SandboxEscape.containerIdentifier(at: canonical),
           identifier.lowercased() == target.lowercased() {
            log("   ✅ 容器标识为 \(identifier)（数据目录稍后自动创建）")
            return true
        }

        if let items = try? FileManager.default.contentsOfDirectory(atPath: canonical + "/Library"), !items.isEmpty {
            log("   ⚠️ 容器可读，但里面没有目标数据目录")
        } else {
            log("   ⚠️ 容器不可读（数据保护未解锁，或不是目标容器）")
        }
        return false
    }

    // MARK: - 批量识别

    /// 在一批路径里找 PosterBoard：xattr 直接读 → 读不到再签发 → 再读不到就看数据目录。
    private static func identify(paths: [String], group: String, target: String, log: (String) -> Void, source: String) -> Hit? {
        guard !paths.isEmpty else { return nil }
        guard let sweeper = SandboxEscape.Sweeper(group: group) else {
            log("   ⚠️ 无法建立批量签发会话（App Group 不可用）")
            return nil
        }
        defer { sweeper.finish() }

        var identified = 0
        var checked = 0
        for path in paths {
            checked += 1
            if checked % 40 == 0 {
                log("   已检查 \(checked)/\(paths.count)…")
            }
            if let identifier = sweeper.identifier(of: path) {
                identified += 1
                if identifier.lowercased() == target.lowercased() {
                    log("   ✅ 认领到 \(target)：\(path)")
                    if target != posterBoardBundleID || sweeper.contains(path, relative: storeRelativePath) || SandboxEscape.exists(path + "/" + storeRelativePath) {
                        sweeper.finish()
                        _ = try? SandboxEscape.grant(path: path, group: group)
                        cacheHit(path)
                        return Hit(path: SandboxEscape.canonicalPath(path), source: source)
                    }
                    log("   ⚠️ 容器对，但里面还没有数据目录，稍后会创建")
                    sweeper.finish()
                    _ = try? SandboxEscape.grant(path: path, group: group)
                    cacheHit(path)
                    return Hit(path: SandboxEscape.canonicalPath(path), source: source)
                }
                continue
            }

            // xattr 读不到：有些容器要签发之后才能读 metadata，退一步看数据目录
            if target == posterBoardBundleID, sweeper.contains(path, relative: storeRelativePath) {
                log("   ✅ 按数据目录命中：\(path)")
                sweeper.finish()
                _ = try? SandboxEscape.grant(path: path, group: group)
                cacheHit(path)
                return Hit(path: SandboxEscape.canonicalPath(path), source: source + " · 目录判定")
            }
        }
        log("   可读标识 \(identified) 个，没有 \(target)")
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
    private static let chunkSize: Int64 = 32_768

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

    private static func scanApplicationContainers(log: (String) -> Void) -> [String] {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fsgetpath") else {
            log("   ⚠️ 系统没有 fsgetpath")
            return []
        }
        let fsgetpath = unsafeBitCast(pointer, to: FSGetPath.self)

        guard let probe = makeProbe() else {
            log("   ⚠️ 无法在 Data 卷上创建探针文件")
            return []
        }

        // 增量：上次扫到哪，就从那附近继续
        var first: Int64 = 1
        if let cached = cachedScanLimit(), cached > 0, cached < probe.limit {
            first = max(1, cached - scanMargin)
            log("   增量扫描 \(first)…\(probe.limit)（上次扫到 \(cached)）")
        } else {
            log("   全量扫描 1…\(probe.limit)")
        }

        // 先抽样，确认 fsgetpath 能看到别的 App；看不到就别白扫几百万次
        guard sampleSeesOthers(fsgetpath: fsgetpath, probe: probe) else {
            log("   ⚠️ fsgetpath 只能解析本 App 自己的文件，这个系统版本拦住了路径反查")
            return []
        }

        let bases = [applicationRoot, pluginRoot, daemonRoot]
        let prefixes = bases.map { Array($0.utf8).map { CChar(bitPattern: $0) } }

        let total = max(0, probe.limit - first + 1)
        let chunks = (total + chunkSize - 1) / chunkSize
        guard chunks > 0 else { return [] }

        var nextChunk: Int64 = 0
        var hits = Set<String>()
        let lock = NSLock()
        let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        let started = Date()

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var local: [String] = []
            var id = probe.fsid
            var buffer = [CChar](repeating: 0, count: 1200)

            while true {
                lock.lock()
                let chunk = nextChunk
                nextChunk += 1
                lock.unlock()
                if chunk >= chunks { break }

                let chunkStart = first + chunk * chunkSize
                let chunkEnd = min(chunkStart + chunkSize - 1, probe.limit)

                buffer.withUnsafeMutableBufferPointer { raw in
                    guard let base = raw.baseAddress else { return }
                    var inode = chunkStart
                    while inode <= chunkEnd {
                        let length = fsgetpath(base, raw.count, &id, UInt64(inode))
                        inode += 1
                        guard length > 0 else { continue }

                        for prefix in prefixes {
                            let count = prefix.count
                            var matched = true
                            var index = 0
                            while index < count {
                                if base[index] != prefix[index] {
                                    matched = false
                                    break
                                }
                                index += 1
                            }
                            guard matched, base[count] == CChar(UInt8(ascii: "/")) else { continue }
                            // 只要直接子项
                            guard strchr(base.advanced(by: count + 1), Int32(UInt8(ascii: "/"))) == nil else { continue }
                            local.append(String(cString: base))
                            break
                        }
                    }
                }

                if !local.isEmpty {
                    lock.lock()
                    hits.formUnion(local)
                    lock.unlock()
                    local.removeAll(keepingCapacity: true)
                }
            }
        }

        let cost = String(format: "%.1f", Date().timeIntervalSince(started))
        log("   扫了 \(total) 个 object id，用时 \(cost) 秒，得到 \(hits.count) 个容器")
        saveScanCache(Array(hits), limit: probe.limit)
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
        let samples = 2000
        let lower = max(1, probe.limit / 2)

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
    }

    private static func loadScanCache() -> [String] {
        let defaults = UserDefaults.standard
        guard let date = defaults.object(forKey: ScanCache.date) as? Date,
              Date().timeIntervalSince(date) < 7 * 24 * 3600,
              let paths = defaults.array(forKey: ScanCache.paths) as? [String]
        else { return [] }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
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
        if UserDefaults.standard.object(forKey: ScanCache.date) == nil {
            UserDefaults.standard.set(Date(), forKey: ScanCache.date)
        }
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

    // MARK: - 父目录（一般列不出来，留作最后尝试）

    private static func scanParentDirectory(group: String, target: String, log: (String) -> Void) -> Hit? {
        do {
            _ = try SandboxEscape.grant(path: applicationRoot, group: group)
        } catch {
            log("   父目录扩展签不出来：\(error.localizedDescription)")
            return nil
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: applicationRoot) else {
            log("   父目录不可枚举（系统限制），需要手动填路径")
            return nil
        }
        log("   枚举到 \(entries.count) 个应用容器，逐个检查…")
        for name in entries.prefix(500) {
            let path = applicationRoot + "/" + name
            if verify(path: path, group: group, target: target, log: { _ in }) {
                cacheHit(path)
                return Hit(path: path, source: "容器列举")
            }
        }
        return nil
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

        for selector in ["applicationProxyForIdentifier:", "applicationProxyForBundleIdentifier:"] {
            if let proxy = sendObject(workspace, selector, posterBoardBundleID as NSString) {
                append(proxy)
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
