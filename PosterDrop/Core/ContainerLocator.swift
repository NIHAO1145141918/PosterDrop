//
//  ContainerLocator.swift
//  PosterDrop
//
//  直连通道专用的容器定位。
//
//  实测（iOS 27.0 / 24A5370h）：container_query 枚举 class 1…14 只返回 0 个容器，
//  容器父目录也不允许 opendir。所以自动定位不能靠“遍历目录”，必须让系统自己
//  把路径交出来：
//
//    ❶ MobileInstallation 的映射 plist —— 路径固定，先拿到该目录的 group 扩展再读；
//    ❷ LaunchServices（对系统 App 常常是 nil，聊胜于无）；
//    ❸ containermanagerd 枚举（带 include_other_owners，部分版本才返回其它 App）；
//    ❹ 按 bundle id 直接查容器；
//    ❺ 容器父目录列举（一般被拒，最后试一次）。
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

        log("❷ 读取 MobileInstallation 的容器映射…")
        for candidate in mobileInstallationCandidates(group: group, log: log) {
            log("   映射返回：\(candidate)")
            if verify(path: candidate, group: group, log: log) {
                return Hit(path: canonical(candidate), source: "MobileInstallation")
            }
        }

        log("❸ 通过 LaunchServices 查询已安装应用…")
        let services = launchServicesContainers()
        log("   LaunchServices 返回 \(services.count) 条容器记录")
        for item in services where matches(item.identifier) {
            log("   命中 \(item.identifier)：\(item.path)")
            if verify(path: item.path, group: group, log: log) {
                return Hit(path: canonical(item.path), source: "LaunchServices")
            }
        }

        log("❹ 向 containermanagerd 枚举容器…")
        let enumerated = enumerateContainers()
        log("   可见容器 \(enumerated.count) 个")
        for item in enumerated where matches(item.identifier) {
            log("   命中 identifier=\(item.identifier)：\(item.path)")
            if verify(path: item.path, group: group, log: log) {
                return Hit(path: canonical(item.path), source: "容器枚举")
            }
        }

        // 有些系统版本枚举得到 path 但拿不到 identifier；退一步逐个验证（限量，避免卡太久）
        let pool = enumerated.filter { $0.path.contains("/Containers/") }.prefix(80)
        if !pool.isEmpty {
            log("   逐个验证枚举到的容器（最多 80 个，可能要十几秒）…")
            for item in pool {
                if verify(path: item.path, group: group, log: { _ in }) {
                    log("   命中：\(item.path)")
                    return Hit(path: canonical(item.path), source: "容器扫描")
                }
            }
        }

        log("❺ 直接按 bundle id 查询容器…")
        if let path = queryByIdentifier(bundleID: posterBoardBundleID, group: group) {
            log("   返回：\(path)")
            if verify(path: path, group: group, log: log) {
                return Hit(path: canonical(path), source: "bundle id 查询")
            }
        }

        log("❻ 尝试列举应用容器父目录…")
        if let hit = scanApplicationContainers(group: group, log: log) {
            return hit
        }

        log("❌ 自动定位没有结果。可以在 WQFiles 的 App Data 里找到 com.apple.PosterBoard，")
        log("   复制它的容器路径，填到诊断页的「容器路径」输入框后再试。")
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

    // MARK: - ❶ MobileInstallation 映射

    /// 这两个 plist 的路径是固定的，不需要先知道任何 UUID。
    private static let mapLocations: [(directory: String, file: String)] = [
        ("/var/mobile/Library/MobileInstallation", "LastLaunchServicesMap.plist"),
        ("/var/mobile/Library/Caches", "com.apple.mobile.installation.plist"),
        ("/var/mobile/Library/MobileInstallation", "com.apple.mobile.installation.plist")
    ]

    private static func mobileInstallationCandidates(group: String, log: (String) -> Void) -> [String] {
        var results: [String] = []
        var tried = Set<String>()

        for location in mapLocations {
            let file = location.directory + "/" + location.file
            guard tried.insert(file).inserted else { continue }

            log("   读取 \(file)…")
            guard (try? SandboxEscape.grant(path: location.directory, group: group)) != nil else {
                log("   ⚠️ 无法为 \(location.directory) 申请扩展（不存在或权限不足）")
                continue
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
                log("   ⚠️ 读不到或解析失败")
                continue
            }

            if let path = findContainer(in: plist, bundleID: posterBoardBundleID) {
                results.append(path)
            } else {
                log("   映射里没有 \(posterBoardBundleID)")
            }
        }
        return results
    }

    /// 在任意结构的 plist 里递归找 bundleID 对应的容器路径。
    private static func findContainer(in object: Any, bundleID: String, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }

        if let dictionary = object as? [String: Any] {
            if let entry = dictionary[bundleID] as? [String: Any] {
                for key in ["DataContainer", "DataContainerURL", "Container", "ContainerURL", "Path"] {
                    if let value = entry[key] as? String, value.contains("/Containers/") {
                        return normalizeContainer(value)
                    }
                }
            }
            for (_, value) in dictionary {
                if let hit = findContainer(in: value, bundleID: bundleID, depth: depth + 1) {
                    return hit
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let hit = findContainer(in: value, bundleID: bundleID, depth: depth + 1) {
                    return hit
                }
            }
        }
        return nil
    }

    private static func normalizeContainer(_ value: String) -> String {
        var path = value
        if path.hasPrefix("file://") {
            path = URL(string: path)?.path ?? path.replacingOccurrences(of: "file://", with: "")
        }
        return path
    }

    // MARK: - ❸/❹ containermanagerd

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

        // 关键：默认只返回调用者自己的容器。想看到其它 App，必须显式打开。
        let setOtherOwners = symbol("container_query_set_include_other_owners", as: QuerySetBool.self)

        let getIdentifier = symbol("container_object_get_identifier", as: ObjectGetIdentifier.self)
            ?? symbol("container_result_get_identifier", as: ObjectGetIdentifier.self)

        var results: [Entry] = []
        var seen = Set<String>()

        for cls in UInt64(1)...UInt64(14) {
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

    private static func matches(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let lower = identifier.lowercased()
        return lower == "com.apple.posterboard" || lower.hasSuffix(".posterboard")
    }

    // MARK: - ❺ 父目录列举

    private static func scanApplicationContainers(group: String, log: (String) -> Void) -> Hit? {
        let parent = "/var/mobile/Containers/Data/Application"
        guard (try? SandboxEscape.grant(path: parent, group: group)) != nil else {
            log("   无法为容器父目录申请扩展（预期行为，系统只按具体容器签发）")
            return nil
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent) else {
            log("   容器父目录不可枚举（系统限制），需要手动填路径")
            return nil
        }
        log("   枚举到 \(entries.count) 个应用容器，逐个检查…")
        for name in entries.prefix(400) {
            let path = parent + "/" + name
            guard FileManager.default.fileExists(atPath: path + "/" + storeRelativePath) else { continue }
            log("   候选：\(path)")
            if verify(path: path, group: group, log: log) {
                return Hit(path: canonical(path), source: "容器列举")
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

        if let list = send(workspace, "allInstalledApplications") as? [AnyObject] {
            for app in list {
                append(app)
                if let plugins = send(app, "plugInKitPlugins") as? [AnyObject] {
                    for plugin in plugins { append(plugin) }
                }
            }
        }

        // 系统 App 不一定出现在 allInstalledApplications 里，按 id 单独查一次。
        for selector in ["applicationProxyForIdentifier:", "applicationProxyForBundleIdentifier:"] {
            if let proxy = sendObject(workspace, selector, posterBoardBundleID as NSString) {
                append(proxy)
            }
        }
        return results
    }

    // MARK: - ❻ 直接按 bundle id 查

    private static func queryByIdentifier(bundleID: String, group: String) -> String? {
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

        // identifiers 既可能是单个 string，也可能是 array，两种都试。
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

            setClass(query, 2)                   // app container
            setOtherOwners?(query, true)
            setIdentifiers(query, value)

            if let result = single(query), let pathPointer = getPath(result) {
                let path = String(cString: pathPointer)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return nil
    }

    private static func canonical(_ path: String) -> String {
        var resolved = (path as NSString).standardizingPath
        if resolved.hasPrefix("/var/") { resolved = "/private" + resolved }
        return resolved
    }
}
