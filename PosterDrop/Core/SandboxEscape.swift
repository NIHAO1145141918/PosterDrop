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

    // MARK: - 并发与缓存

    /// 整个进程同一时间只能有一个 Caches 交换。它同时保护「交换 → 查询 → 验证」这段临界区。
    private static let gate = NSRecursiveLock()

    private static var grants: [String: EscapeSession] = [:]
    private static var grantOrder: [String] = []
    /// 内核允许的扩展数量有限。WQFiles 用 192，这里保持一致。
    private static let maxGrants = 192

    private static func cached(_ key: String) -> EscapeSession? {
        guard let session = grants[key] else { return nil }
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
        guard handle >= 0 else { return }
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_release") else { return }
        typealias Release = @convention(c) (Int64) -> Void
        let releaseHandle = unsafeBitCast(pointer, to: Release.self)
        _ = releaseHandle(handle)
    }

    // MARK: - 申请

    /// 给一个已经存在的目录/文件申请扩展。
    /// - Parameter requireWrite: 为 true 时，签发后真的在目录里建一个探针文件，建不出来就算失败。
    @discardableResult
    static func grant(path: String, group: String, requireWrite: Bool = false) throws -> EscapeSession {
        let canonical = canonicalPath(path)

        gate.lock()
        defer { gate.unlock() }

        if let hit = cached(canonical), !requireWrite || hit.writable {
            return hit
        }

        var status = stat()
        guard lstat(canonical, &status) == 0 else {
            throw Failure(code: -255, message: "目标不存在：\(canonical)")
        }
        let isDirectory = (status.st_mode & S_IFMT) == S_IFDIR

        guard let base = groupContainerPath(group) else {
            throw Failure(code: -1, message: "App Group 容器不存在，签名里缺少 \(group) 的 entitlement")
        }

        // iOS 27 先试标准 flags，iOS 26 先试备用 flags；成功的那组会记下来。
        let preferAlt = preferredAltFlags()
        let candidates: [UInt64] = preferAlt
            ? [altFlags, standardFlags]
            : [standardFlags, altFlags]

        var lastCode: Int64 = -5
        for flags in candidates {
            let handle: Int64
            do {
                let swap = try CacheSwap(library: base + "/Library")
                defer { swap.finish() }
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
                remember(session, key: canonical)
                noteWorkingFlags(flags == altFlags)
                return session
            }

            // 签发并 consume 都成功，却打不开目标：换另一组 flags 重来
            release(handle)
            lastCode = -8
        }

        throw Failure(code: lastCode, message: describe(lastCode))
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
    private static var workingFlags: UInt64?

    private static func preferredAltFlags() -> Bool {
        guard let workingFlags else {
            return ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
        }
        return workingFlags == altFlags
    }

    private static func noteWorkingFlags(_ alt: Bool) {
        guard workingFlags == nil else { return }
        workingFlags = alt ? altFlags : standardFlags
    }

    // MARK: - 查询

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
    /// 前置条件：`<group>/Library/Caches` 此刻已是指向目标路径的符号链接，且已持有 gate。
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
        let identifier = xpcString(group)
        setGroups(query, identifier)
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
