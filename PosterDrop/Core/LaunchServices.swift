import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

/// 通过 LaunchServices 按 bundleID 直接查数据容器路径。
///
/// 这条路的性质和「签发父目录再枚举」完全不同：`dataContainerURL` 是
/// `LSApplicationProxy` 上的一个普通属性，取值只是一次 ObjC 消息，
/// 不需要签发、不需要遍历、不需要配对。
///
/// 3105 用它给 App 列表配图标（`AppIconHelper.m` 里的 `dataContainerURL` /
/// `containerURL` 双取），AirCard 用的是配对后 installation_proxy 的 `Container`
/// 字段——后者要 LocalDevVPN 和配对文件，前者在沙箱里就能问。
///
/// 系统在某些版本会把这个字段裁掉（返回 nil）。那时整条查询只有几微秒，
/// 调用方直接落到下一条路，不需要额外判断。
enum LaunchServices {

    // MARK: - 对外查询

    /// 按 bundleID 取数据容器路径。拿不到或拿到的不是容器返回 nil。
    static func containerPath(for bundleID: String) -> String? {
        guard let proxy = proxy(for: bundleID) else { return nil }
        return containerPath(of: proxy)
    }

    /// App 显示名。清理页把 UUID 标题换成真名时用，拿不到由调用方退回原值。
    static func displayName(for bundleID: String) -> String? {
        guard let proxy = proxy(for: bundleID) else { return nil }
        for selector in ["localizedName", "itemName"] {
            if let name = call(proxy, selector) as? String, !name.isEmpty { return name }
        }
        return nil
    }

    /// 诊断用：能枚举到多少个 App、其中多少个带可读容器路径。
    /// 对应 3105 那条 `ls: extracted N apps (M with container)`。
    static func census() -> (total: Int, withContainer: Int) {
        let apps = proxies()
        var withContainer = 0
        for app in apps where containerPath(of: app) != nil { withContainer += 1 }
        return (apps.count, withContainer)
    }

    /// 全部带容器路径的 App，供「枚举认领」这条兜底路使用。
    static func containers() -> [(identifier: String, path: String)] {
        var result: [(String, String)] = []
        var seen = Set<String>()
        for app in proxies() {
            guard let identifier = call(app, "bundleIdentifier") as? String,
                  !identifier.isEmpty,
                  let path = containerPath(of: app),
                  seen.insert(identifier + "|" + path).inserted
            else { continue }
            result.append((identifier, path))
        }
        return result
    }

    // MARK: - 取值

    /// `applicationProxyForIdentifier:` 是 LSApplicationProxy 的**类方法**，
    /// 不是 workspace 的实例方法。发错接收者会安静返回 nil，只能靠全表兜底。
    private static func proxy(for bundleID: String) -> AnyObject? {
        guard let cls = NSClassFromString("LSApplicationProxy") else { return nil }
        for selector in ["applicationProxyForIdentifier:", "applicationProxyForBundleIdentifier:"] {
            if let proxy = call(cls as AnyObject, selector, bundleID as NSString) { return proxy }
        }
        return nil
    }

    private static func proxies() -> [AnyObject] {
        guard let cls = NSClassFromString("LSApplicationWorkspace"),
              let workspace = call(cls as AnyObject, "defaultWorkspace")
        else { return [] }

        var result: [AnyObject] = []
        var seen = Set<ObjectIdentifier>()
        for selector in ["allApplications", "allInstalledApplications"] {
            guard let list = call(workspace, selector) as? [AnyObject] else { continue }
            for item in list where seen.insert(ObjectIdentifier(item)).inserted {
                result.append(item)
            }
        }
        return result
    }

    private static func containerPath(of proxy: AnyObject) -> String? {
        for selector in ["dataContainerURL", "containerURL"] {
            if let url = call(proxy, selector) as? URL, isContainerPath(url.path) { return url.path }
            if let text = call(proxy, selector) as? String, isContainerPath(text) { return text }
        }
        return nil
    }

    /// 只接受真正指向 App 数据容器的路径。
    ///
    /// iOS 27.3 实测：`dataContainerURL` 对系统 App 会返回 `/var/mobile`——
    /// 一个父目录，不是容器。拿它去签发只会换来一次 -6，白等一次失败。
    /// 形状校验挡在前面，比事后判断错误码便宜。
    private static func isContainerPath(_ raw: String) -> Bool {
        var path = raw
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        let prefix = "/var/mobile/Containers/Data/"
        guard path.hasPrefix(prefix) else { return false }

        let parts = path.dropFirst(prefix.count).split(separator: "/")
        guard parts.count >= 2 else { return false }
        let kinds: Set<String> = ["Application", "PluginKitPlugin", "InternalDaemon"]
        guard kinds.contains(String(parts[0])) else { return false }
        return UUID(uuidString: String(parts[1])) != nil
    }

    // MARK: - ObjC 消息

    private typealias Send0 = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias Send1 = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?

    /// 实例方法和类方法共用一套：`object_getClass` 对实例返回类，对类返回元类，
    /// 而类方法在运行时正是元类的实例方法，所以一次查找两边都覆盖。
    private static func call(_ target: AnyObject, _ name: String, _ argument: AnyObject? = nil) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let meta = object_getClass(target),
              let method = class_getInstanceMethod(meta, selector)
        else { return nil }

        let implementation = method_getImplementation(method)
        if let argument {
            let send = unsafeBitCast(implementation, to: Send1.self)
            return send(target, selector, argument)?.takeUnretainedValue()
        }
        let send = unsafeBitCast(implementation, to: Send0.self)
        return send(target, selector)?.takeUnretainedValue()
    }
}
