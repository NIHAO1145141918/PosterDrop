//
//  InstallationProxy.swift
//  PosterDrop
//
//  通过 RSD 调 installation_proxy，一次拿全量 App 清单。
//
//  这是 3105 / AirCard 快的真正原因：`Browse` 一条命令返回所有已安装 App，
//  每条记录自带 `Container` 字段（就是 Data/Application/<UUID>）。
//  对照我们用 fsgetpath 问 1.2 亿个 inode —— 一次 XPC 换 250 秒。
//
//  协议：RSD 上的服务连接是裸 plist 流（无长度前缀），服务端按 XML 边界切分。
//  所以读的时候以 `</plist>` 为界，一次可能收到多份。
//

import Foundation

struct InstalledApp {
    let bundleID: String
    let container: String?
    let name: String?
    let applicationType: String?
}

enum InstallationProxyError: LocalizedError {
    case noService
    case status(String)

    var errorDescription: String? {
        switch self {
        case .noService:
            return "设备没有暴露 com.apple.installation_proxy"
        case let .status(message):
            return "installation_proxy 返回错误：\(message)"
        }
    }
}

enum InstallationProxy {

    static let serviceName = "com.apple.installation_proxy"

    /// Browse：拿全部 App。失败抛错，调用方负责回退。
    static func browse(
        handshake: RSDHandshake,
        identity: sec_identity_t?,
        timeout: TimeInterval = 20,
        log: (String) -> Void = { _ in }
    ) throws -> [InstalledApp] {
        guard let service = handshake.service(serviceName) else {
            throw InstallationProxyError.noService
        }

        let link = try RSDLink(
            host: handshake.host,
            port: service.port,
            identity: service.usesTLS ? identity : nil,
            timeout: min(timeout, 10)
        )
        defer { link.close() }

        let request: [String: Any] = [
            "Command": "Browse",
            "ClientOptions": [
                "ApplicationType": "Any",
                "ShowLaunchProhibitedApps": true
            ]
        ]
        try send(request, over: link)
        log("   已发送 Browse，等待分片…")

        var apps: [InstalledApp] = []
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(timeout)
        var rounds = 0

        while Date() < deadline {
            let frame = try link.readUntil(
                marker: Data("</plist>".utf8),
                timeout: max(1, deadline.timeIntervalSinceNow)
            )
            guard let dictionary = parse(frame) else {
                // 不是完整 plist，继续等下一片
                continue
            }
            rounds += 1

            if let message = dictionary["Error"] as? String {
                throw InstallationProxyError.status(message)
            }
            if let description = dictionary["ErrorDescription"] as? String {
                throw InstallationProxyError.status(description)
            }

            for app in extract(dictionary) where seen.insert(app.bundleID).inserted {
                apps.append(app)
            }

            let status = (dictionary["Status"] as? String) ?? ""
            if status == "Complete" {
                log("   Browse 完成：\(apps.count) 个 App（\(rounds) 片）")
                return apps
            }
            // BrowsingApplications / 其他中间态：继续读
        }

        log("   Browse 超时，已收到 \(apps.count) 个 App")
        return apps
    }

    /// Lookup：按 bundleID 查单个，用于定位已知 App 时补齐信息。
    static func lookup(
        _ bundleIDs: [String],
        handshake: RSDHandshake,
        identity: sec_identity_t?,
        timeout: TimeInterval = 10
    ) throws -> [InstalledApp] {
        guard !bundleIDs.isEmpty else { return [] }
        guard let service = handshake.service(serviceName) else {
            throw InstallationProxyError.noService
        }

        let link = try RSDLink(
            host: handshake.host,
            port: service.port,
            identity: service.usesTLS ? identity : nil,
            timeout: min(timeout, 8)
        )
        defer { link.close() }

        let request: [String: Any] = [
            "Command": "Lookup",
            "ClientOptions": ["ApplicationType": "Any"],
            "BundleIDs": bundleIDs
        ]
        try send(request, over: link)

        let frame = try link.readUntil(
            marker: Data("</plist>".utf8),
            timeout: timeout
        )
        guard let dictionary = parse(frame) else { return [] }
        return extract(dictionary)
    }

    // MARK: - 收发

    private static func send(_ request: [String: Any], over link: RSDLink) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: request, format: .xml, options: 0
        )
        try link.send(data)
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) else { return nil }
        return plist as? [String: Any]
    }

    private static func extract(_ dictionary: [String: Any]) -> [InstalledApp] {
        // 顶层可能是单条，也可能是 CurrentList 数组
        var entries: [[String: Any]] = []
        if let list = dictionary["CurrentList"] as? [[String: Any]] {
            entries = list
        } else if let list = dictionary["CurrentList"] as? [String: Any] {
            entries = [list]
        } else if dictionary["CFBundleIdentifier"] != nil {
            entries = [dictionary]
        }

        return entries.compactMap { entry in
            guard let bundleID = entry["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
                return nil
            }
            let container = Self.containerPath(in: entry)
            let displayName = (entry["CFBundleDisplayName"] as? String)
                ?? (entry["CFBundleName"] as? String)
            return InstalledApp(
                bundleID: bundleID,
                container: container,
                name: displayName,
                applicationType: entry["ApplicationType"] as? String
            )
        }
    }

    /// `Container` 有时是字符串，有时把路径塞在别的键里；只认形状对的。
    private static func containerPath(in entry: [String: Any]) -> String? {
        let keys = ["Container", "DataContainer", "ContainerURL", "DataContainerURL"]
        for key in keys {
            guard let value = entry[key] else { continue }
            let path: String?
            if let text = value as? String {
                path = text
            } else if let data = value as? Data {
                path = String(data: data, encoding: .utf8)
            } else {
                path = nil
            }
            guard let candidate = path, !candidate.isEmpty else { continue }
            // 只接受容器目录，避免把 "/var/mobile" 这种父目录当结果。
            // 27.3 上 LSApplicationProxy 就返回过 /var/mobile，必须挡掉。
            if candidate.contains("/Containers/Data/") {
                return candidate
            }
        }
        return nil
    }
}
