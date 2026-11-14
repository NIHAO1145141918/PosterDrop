//
//  ContainerIndex.swift
//  PosterDrop
//
//  按 bundleID 直接拿 App 数据容器，而不是靠 UUID 目录名去猜。
//
//  为什么需要这一层：
//    /private/var/mobile/Containers/Data/Application 下面是一堆 UUID 目录，
//    目录名里没有任何 App 信息。想知道「这 190 MB 是谁的」，只能进去读 xattr；
//    想按 App 排序、想只清某一个 App，也都要先建立 UUID → bundleID 的映射。
//    containermanagerd 自己的索引里本来就有这张表，只是要按它的接口问。
//
//  这一层只做三件事，全部是可失败的探测，失败就返回 nil 让调用方回落到目录遍历：
//    1. 枚举：class 2（App 数据容器）一次性取出 identifier + 路径；
//    2. 定位：按 identifier 查单个容器的路径；
//    3. 激活：container_object_sandbox_extension_activate 把容器挂到本进程的沙箱上。
//
//  注意 flags：这里沿用 0x1_0000_0000，和 3105 的 MCM 桥接一致。换成别的值
//  containermanagerd 会直接返回空结果，而且不报错，很难查。
//
//  没有 com.apple.private.security.container-manager 的签名，枚举通常会被拒。
//  这种情况下 iterate 返回 false、结果为空，全部回落，不影响既有功能。
//

import Foundation
import Darwin

enum ContainerIndex {

    /// 一个 App 数据容器的索引项。
    struct Entry: Sendable {
        /// App 的 bundle identifier；个别系统容器为空
        let identifier: String?
        /// 容器的绝对路径（已规范成 /private/var/...）
        let path: String
    }

    /// MCM 的容器类别：2 = App 数据容器（Application）
    private static let applicationClass: UInt64 = 2
    /// 查询标志。3105 用这个值；换值会静默返回空结果。
    private static let queryFlags: UInt64 = 0x1_0000_0000
    /// 一次最多取多少条。设备上装 400 个 App 也够了。
    private static let maxEntries = 1_024

    // MARK: - 符号

    private typealias QueryCreate = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias QuerySetClass = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetIDs = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias QuerySetFlags = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetPart = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySingle = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias QueryIterate = @convention(c) (
        UnsafeMutableRawPointer?,
        @convention(block) (UnsafeMutableRawPointer?) -> Bool
    ) -> Bool
    private typealias QueryFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias ObjectPath = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
    private typealias ObjectIdentifier = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
    private typealias ObjectActivate = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    private typealias CopyToken = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    private typealias XPCString = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias XPCCreate = @convention(c) (UnsafePointer<CChar>?, Int) -> UnsafeMutableRawPointer?
    private typealias XPCRelease = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Consume = @convention(c) (UnsafePointer<CChar>?) -> Int64

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
        static let querySetIDs = load("container_query_set_identifiers", in: manager, as: QuerySetIDs.self)
        static let querySetFlags = load("container_query_operation_set_flags", in: manager, as: QuerySetFlags.self)
        static let querySetPart = load("container_query_operation_set_part", in: manager, as: QuerySetPart.self)
        static let querySingle = load("container_query_get_single_result", in: manager, as: QuerySingle.self)
        static let queryIterate = load("container_query_iterate_results_sync", in: manager, as: QueryIterate.self)
        static let queryFree = load("container_query_free", in: manager, as: QueryFree.self)

        static let objectPath = load("container_object_get_path", in: manager, as: ObjectPath.self)
        static let objectIdentifier = load("container_object_get_identifier", in: manager, as: ObjectIdentifier.self)
        static let objectActivate = load("container_object_sandbox_extension_activate", in: manager, as: ObjectActivate.self)
        static let copyToken = load("container_copy_sandbox_token", in: manager, as: CopyToken.self)

        static let xpcString = load("xpc_string_create", in: xpc, as: XPCString.self)
        static let xpcRelease = load("xpc_release", in: xpc, as: XPCRelease.self)

        static let consume: Consume? = {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_consume") else {
                return nil
            }
            return unsafeBitCast(pointer, to: Consume.self)
        }()

        static var enumerable: Bool {
            queryCreate != nil && querySetClass != nil && querySetFlags != nil
                && queryIterate != nil && queryFree != nil && objectPath != nil
        }
    }

    /// 上一次探测的结论。枚举被拒时不必每次扫描都再问一遍。
    private static let probeLock = NSLock()
    private static var enumerationDenied = false
    private static var lastDenialReason: String?

    /// 上一次枚举为什么不可用。给日志用，避免用户每次只看到「不可用」三个字。
    static var denialReason: String? {
        probeLock.lock()
        defer { probeLock.unlock() }
        return lastDenialReason
    }

    /// 别的 App 容器少于这个数，就认为沙盒只放行了本 App，这条路径没有意义。
    ///
    /// iOS 上无 container-manager 权限时，`container_query_set_class(2)` 不报错，
    /// 而是安静地只返回调用者自己的容器。真机上实测就是 1 条。
    /// 不设阈值的话，这里会把「只扫到自己」当成成功，后面的慢路径永远走不到。
    private static let minimumOthers = 3

    // MARK: - 枚举

    /// 一次性取出所有 App 数据容器。
    /// - Parameter activate: 顺带把每个容器挂到本进程沙箱上（`container_object_sandbox_extension_activate`）。
    ///   挂上之后 open 就不需要再走 Caches 交换那套，代价是每个容器一次内核调用。
    /// - Returns: 成功时返回条目（可能为空数组）；接口不可用、被拒、或只放行了自己时返回 nil。
    /// 列某一类容器的标识。只用来诊断：确认 systemgroup 里到底有哪些 group、
    /// 签名注入的 App Group 在不在系统表里。
    ///
    /// 和 snapshot 的区别是不传 identifiers、不取路径，纯粹枚举。
    /// 被拒时返回空数组，符号缺失返回 nil。
    static func identifiers(containerClass: UInt64, limit: Int = 200) -> [String]? {
        guard let create = Symbols.queryCreate,
              let setClass = Symbols.querySetClass,
              let setFlags = Symbols.querySetFlags,
              let iterate = Symbols.queryIterate,
              let free = Symbols.queryFree,
              let getIdentifier = Symbols.objectIdentifier
        else { return nil }

        guard let query = create() else { return nil }
        defer { free(query) }

        setClass(query, containerClass)
        setFlags(query, queryFlags)
        Symbols.querySetPart?(query, 0)

        var out: [String] = []
        let completed = iterate(query) { object in
            guard let object, let raw = getIdentifier(object) else { return true }
            let value = String(cString: raw)
            if !value.isEmpty { out.append(value) }
            return out.count < limit
        }
        // 一条都没拿到且迭代没走完 = 被 daemon 拒绝；空数组 = 这类容器确实是空的
        if out.isEmpty, !completed { return nil }
        return out
    }

    static func snapshot(activate: Bool = false, limit: Int = maxEntries) -> [Entry]? {
        guard Symbols.enumerable else {
            record(denial: "缺少 container_query 符号")
            return nil
        }

        probeLock.lock()
        let denied = enumerationDenied
        probeLock.unlock()
        if denied { return nil }

        guard let create = Symbols.queryCreate,
              let setClass = Symbols.querySetClass,
              let setFlags = Symbols.querySetFlags,
              let iterate = Symbols.queryIterate,
              let free = Symbols.queryFree,
              let getPath = Symbols.objectPath
        else { return nil }

        guard let query = create() else { return nil }
        defer { free(query) }

        setClass(query, applicationClass)
        setFlags(query, queryFlags)
        Symbols.querySetPart?(query, 0)

        let ownRoot = canonicalize(NSHomeDirectory())
        var entries: [Entry] = []
        entries.reserveCapacity(limit)
        var skippedSelf = 0

        let completed = iterate(query) { object in
            guard let object else { return true }
            guard let rawPath = getPath(object) else { return true }
            let path = canonicalize(String(cString: rawPath))
            guard path.hasPrefix("/private/var/"), path.count > 16 else { return true }

            // 自己的容器不算「其他 App」——它也进不了清理列表（本 App 单独两项）
            if path == ownRoot {
                skippedSelf += 1
                return true
            }

            var identifier: String?
            if let getIdentifier = Symbols.objectIdentifier, let raw = getIdentifier(object) {
                let value = String(cString: raw)
                identifier = value.isEmpty ? nil : value
            }

            if activate, let activateObject = Symbols.objectActivate {
                _ = activateObject(object)
            }

            entries.append(Entry(identifier: identifier, path: path))
            return entries.count < limit
        }

        if entries.count >= minimumOthers {
            return entries
        }

        // 拿到的容器少得不像一台正常设备：只能是自己，或者干脆被拒。
        let reason: String
        if entries.isEmpty {
            reason = completed ? "索引为空（沙盒只允许本 App）" : "containermanagerd 拒绝枚举"
        } else {
            reason = "索引只给出 \(entries.count + skippedSelf) 个容器（含自己），判定为沙盒限制"
        }
        record(denial: reason)
        return nil
    }

    private static func record(denial reason: String) {
        probeLock.lock()
        enumerationDenied = true
        lastDenialReason = reason
        probeLock.unlock()
    }

    /// 按 bundleID 查单个容器的路径。比枚举便宜，适合「只想知道某一个 App」。
    static func path(for identifier: String) -> String? {
        guard Symbols.queryCreate != nil,
              let create = Symbols.queryCreate,
              let setClass = Symbols.querySetClass,
              let setIDs = Symbols.querySetIDs,
              let setFlags = Symbols.querySetFlags,
              let single = Symbols.querySingle,
              let free = Symbols.queryFree,
              let getPath = Symbols.objectPath,
              let makeString = Symbols.xpcString
        else { return nil }

        guard let query = create() else { return nil }
        defer { free(query) }

        setClass(query, applicationClass)
        setFlags(query, queryFlags)
        Symbols.querySetPart?(query, 0)

        let value = makeString(identifier)
        defer { if let value, let release = Symbols.xpcRelease { release(value) } }
        setIDs(query, value)

        guard let result = single(query), let rawPath = getPath(result) else { return nil }
        let path = canonicalize(String(cString: rawPath))
        return path.hasPrefix("/private/var/") ? path : nil
    }

    /// 把某个已经查到的容器挂到本进程沙箱上。
    ///
    /// `container_object_sandbox_extension_activate` 内部做的事就是
    /// copy_token + sandbox_extension_consume，但省掉了我们自己拼路径这一步。
    /// 查询结果只在闭包内有效，所以这里重新查一次，只激活不读内容。
    @discardableResult
    static func activate(identifier: String) -> Bool {
        guard let create = Symbols.queryCreate,
              let setClass = Symbols.querySetClass,
              let setIDs = Symbols.querySetIDs,
              let setFlags = Symbols.querySetFlags,
              let single = Symbols.querySingle,
              let free = Symbols.queryFree,
              let activateObject = Symbols.objectActivate
        else { return false }

        guard let query = create() else { return false }
        defer { free(query) }

        setClass(query, applicationClass)
        setFlags(query, queryFlags)
        Symbols.querySetPart?(query, 0)

        if let makeString = Symbols.xpcString, let release = Symbols.xpcRelease {
            let value = makeString(identifier)
            defer { if let value { release(value) } }
            setIDs(query, value)
        } else {
            return false
        }

        guard let result = single(query) else { return false }
        return activateObject(result)
    }

    // MARK: - 工具

    /// /var 和 /private/var 是同一个地方，统一成后者，避免同一个容器算两次。
    private static func canonicalize(_ path: String) -> String {
        var value = (path as NSString).standardizingPath
        if value.hasPrefix("/var/") { value = "/private" + value }
        return value
    }
}
