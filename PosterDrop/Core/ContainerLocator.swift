//
//  ContainerLocator.swift
//  PosterDrop
//
//  直连通道专用的容器定位。
//
//  这里有个反直觉的事实（WQFiles 的实测结论）：拿到沙箱扩展也**列不出**
//  Data/Application 这种容器父目录——token 是按具体容器签的，父目录本身不是容器。
//  所以不能靠遍历目录找 PosterBoard，只能按标识反查：
//
//    1. containermanagerd 的枚举接口（class 1…14），用 identifier 匹配；
//    2. LaunchServices 的 LSApplicationWorkspace，取 dataContainerURL；
//    3. container_query 直接按 bundle id 查（通常被拒，聊胜于无）；
//    4. 用户手动粘贴的路径（WQFiles / Filza 里能直接看到）。
//
//  找到候选后必须验证：申请扩展 → 看 <容器>/Library/Application Support/PRBPosterExtensionDataStore
//  是否存在。只有这一步通过，才算真的可用。
//

import Foundation
import Darwin
import ObjectiveC

enum ContainerLocator {

    static let posterBoardBundleID = "com.apple.PosterBoard"
    private static let storeRelativePath = "Library/Application Support/PRBPosterExtensionDataStore"

    struct Hit {
        let path: String
        let source: String
    }

    // MARK: - 对外入口

    static func findPosterBoard(group: String, manual: String?, log: (String) -> Void) -> Hit? {
        let manualPath = (manual ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !manualPath.isEmpty {
            log("① 手动路径：\(manualPath)")
            if verify(path: manualPath, group: group, log: log) {
                return Hit(path: canonical(manualPath), source: "手动填写")
            }
            log("   该路径下没有 PRBPosterExtensionDataStore，继续自动查找")
        }

        log("① 向 containermanagerd 枚举容器…")
        let enumerated = enumerateContainers()
        log("   可见容器 \(enumerated.count) 个")
        for item in enumerated where matches(item.identifier) {
            log("   命中 identifier=\(item.identifier)：\(item.path)")
            if verify(path: item.path, group: group, log: log) {
                return Hit(path: canonical(item.path), source: "容器枚举")
            }
        }

        log("② 通过 LaunchServices 查询已安装应用…")
        for item in launchServicesContainers() where matches(item.identifier) {
            log("   命中 \(item.identifier)：\(item.path)")
            if verify(path: item.path, group: group, log: log) {
                return Hit(path: canonical(item.path), source: "LaunchServices")
            }
        }

        log("③ 直接按 bundle id 查询容器…")
        if let path = queryByIdentifier(bundleID: posterBoardBundleID, group: group) {
            log("   返回：\(path)")
            if verify(path: path, group: group, log: log) {
                return Hit(path: canonical(path), source: "bundle id 查询")
            }
        }

        log("❌ 三条自动路径都没有结果。可以在 WQFiles 的 App Data 里找到 com.apple.PosterBoard，复制它的容器路径填到上面。")
        return nil
    }

    // MARK: - 验证

    static func verify(path: String, group: String, log: (String) -> Void) -> Bool {
        do {
            _ = try SandboxEscape.grant(path: path, group: group)
        } catch {
            log("   ⚠️ 申请扩展失败：\(error.localizedDescription)")
            return false
        }

        let store = path + "/" + storeRelativePath
        if FileManager.default.fileExists(atPath: store) {
            log("   ✅ \(store)")
            return true
        }

        // 有些系统版本把 store 放在扩展自己的容器里，退一步看 Library 是否可读
        let library = path + "/Library"
        if let items = try? FileManager.default.contentsOfDirectory(atPath: library), !items.isEmpty {
            log("   ⚠️ 容器可读，但没有 PRBPosterExtensionDataStore（可能系统版本不同）")
        } else {
            log("   ⚠️ 容器不可读（数据保护未解锁，或不是目标容器）")
        }
        return false
    }

    // MARK: - 枚举

    private struct Entry {
        let path: String
        let identifier: String
    }

    private typealias QueryCreate = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias QuerySetClass = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
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

        let getIdentifier = symbol("container_object_get_identifier", as: ObjectGetIdentifier.self)
            ?? symbol("container_result_get_identifier", as: ObjectGetIdentifier.self)

        var results: [Entry] = []
        var seen = Set<String>()

        for cls in UInt64(1)...UInt64(14) {
            guard let query = create() else { continue }
            setClass(query, cls)
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

    private static func matches(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let lower = identifier.lowercased()
        return lower == "com.apple.posterboard" || lower.hasSuffix(".posterboard")
    }

    // MARK: - LaunchServices

    private typealias MsgSend = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?

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

    private static func launchServicesContainers() -> [Entry] {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace"),
              let workspace = sendClass(workspaceClass, "defaultWorkspace"),
              let list = send(workspace, "allInstalledApplications") as? [AnyObject]
        else { return [] }

        var results: [Entry] = []

        func append(_ proxy: AnyObject) {
            guard let identifier = send(proxy, "bundleIdentifier") as? String,
                  let url = send(proxy, "dataContainerURL") as? URL,
                  !url.path.isEmpty
            else { return }
            results.append(Entry(path: url.path, identifier: identifier))
        }

        for app in list {
            append(app)
            if let plugins = send(app, "plugInKitPlugins") as? [AnyObject] {
                for plugin in plugins { append(plugin) }
            }
        }
        return results
    }

    // MARK: - 直接按 bundle id 查

    private static func queryByIdentifier(bundleID: String, group: String) -> String? {
        guard let manager = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        defer { dlclose(manager) }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(manager, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        typealias QuerySetIDs = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        typealias QueryGetSingle = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        typealias XPCStringCreate = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

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

        let xpcString = unsafeBitCast(xpcPointer, to: XPCStringCreate.self)
        guard let query = create() else { return nil }
        defer { freeQuery(query) }

        setClass(query, 2)                       // app container
        setIdentifiers(query, xpcString(bundleID))
        guard let result = single(query), let pathPointer = getPath(result) else { return nil }
        return String(cString: pathPointer)
    }

    private static func canonical(_ path: String) -> String {
        var resolved = (path as NSString).standardizingPath
        if resolved.hasPrefix("/var/") { resolved = "/private" + resolved }
        return resolved
    }
}
