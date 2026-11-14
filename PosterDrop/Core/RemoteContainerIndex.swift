//
//  RemoteContainerIndex.swift
//  PosterDrop
//
//  远程容器索引：把 installation_proxy 拿到的 App 清单变成「容器路径列表」，
//  并缓存下来给清理页用。
//
//  定位顺序里的位置：
//    ⓪ 上次命中的路径
//    ⓪.5（新增）远程索引 —— 1–2 秒拿到全部 App 的容器
//    ①…⑤ 原有的 fsgetpath 反查
//
//  远程索引失败一律静默回退，不影响现有流程。
//

import Foundation
import Security

struct RemoteProbeReport: Sendable {
    enum State: String {
        case noPairing      = "未导入配对文件"
        case pairingBroken  = "配对文件不可用"
        case unreachable    = "RSD 连不上"
        case rejected       = "设备拒绝握手"
        case empty          = "RSD 通了但没有 App"
        case ok             = "正常"
    }

    let state: State
    let appCount: Int
    let containerCount: Int
    let host: String
    let detail: String
    let elapsed: TimeInterval

    var isUsable: Bool { state == .ok && containerCount > 0 }

    var logLine: String {
        let cost = String(format: "%.2f", elapsed)
        if state == .ok {
            return "远程索引：\(appCount) 个 App，\(containerCount) 个带容器（\(host)，\(cost)s）"
        }
        return "远程索引不可用：\(state.rawValue)（\(detail)，\(cost)s）"
    }
}

final class RemoteContainerIndex {

    static let shared = RemoteContainerIndex()

    private enum Keys {
        static let apps = "posterdrop.remote.apps"
        static let updatedAt = "posterdrop.remote.updatedAt"
    }

    private struct CachedApp: Codable {
        let bundleID: String
        let container: String?
        let name: String?
    }

    private let lock = NSLock()
    private var lastReport: RemoteProbeReport?
    private var lastFailureAt: Date?
    private var inFlight = false
    /// 失败后的冷却时间。定位流程会在每次 find 时问一次缓存，
    /// 没有冷却的话「配对文件不对」会让每次定位都白等一次 TLS 超时。
    private let failureCooldown: TimeInterval = 300

    // MARK: - 对外

    /// 缓存是否还新鲜。默认 24 小时——App 装卸不频繁，但也不能永久不刷新。
    func isFresh(maxAge: TimeInterval = 24 * 3600) -> Bool {
        guard let date = UserDefaults.standard.object(forKey: Keys.updatedAt) as? Date else {
            return false
        }
        return Date().timeIntervalSince(date) < maxAge
    }

    /// 拿容器列表。有新鲜缓存直接给；否则探测一次。
    /// 失败返回空数组（调用方继续走 fsgetpath）。
    func snapshot(log: @escaping (String) -> Void) -> [String] {
        guard PairingStore.shared.hasPairing else { return [] }

        if isFresh(), let cached = cachedContainers(), !cached.isEmpty {
            log("远程索引：复用缓存（\(cached.count) 个容器）")
            return cached
        }

        // 刚失败过就别再试：一次 TLS 超时是 8 秒，不该让每次清理都等一遍
        lock.lock()
        let failureAge = lastFailureAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        lock.unlock()
        if failureAge < failureCooldown {
            return []
        }

        let report = probe(log: log)
        guard report.isUsable else { return [] }
        return cachedContainers() ?? []
    }

    /// 探测一次，同时刷新缓存。诊断页和清理页共用。
    @discardableResult
    func probe(timeout: TimeInterval = 12, log: @escaping (String) -> Void) -> RemoteProbeReport {
        lock.lock()
        if inFlight {
            lock.unlock()
            // 另一个线程正在探测，等它写完缓存
            for _ in 0..<60 {
                Thread.sleep(forTimeInterval: 0.25)
                lock.lock()
                let running = inFlight
                lock.unlock()
                if !running { break }
            }
            lock.lock()
            let report = lastReport
            lock.unlock()
            return report ?? failed(.unreachable, detail: "探测未完成", host: "-", elapsed: 0)
        }
        inFlight = true
        lock.unlock()

        defer {
            lock.lock()
            inFlight = false
            lock.unlock()
        }

        let started = Date()
        let host = RSDClient.defaultHost

        guard PairingStore.shared.hasPairing else {
            let report = failed(.noPairing, detail: "去诊断页导入", host: host, elapsed: 0)
            store(report)
            return report
        }

        let identity: SecIdentity
        do {
            identity = try PairingStore.shared.identity()
        } catch {
            let report = failed(
                .pairingBroken,
                detail: error.localizedDescription,
                host: host,
                elapsed: Date().timeIntervalSince(started)
            )
            store(report)
            return report
        }

        let handshake: RSDHandshake
        do {
            handshake = try RSDClient.handshake(timeout: min(timeout, 8), log: log)
        } catch {
            let message = error.localizedDescription
            let state: RemoteProbeReport.State = message.contains("拒绝") ? .rejected : .unreachable
            let report = failed(
                state,
                detail: message,
                host: host,
                elapsed: Date().timeIntervalSince(started)
            )
            store(report)
            return report
        }

        log("   服务表：\(handshake.serviceNames.count) 项，含 installation_proxy：\(handshake.service("com.apple.installation_proxy") != nil)")

        let apps: [InstalledApp]
        do {
            apps = try InstallationProxy.browse(
                handshake: handshake,
                identity: identity,
                timeout: timeout,
                log: log
            )
        } catch {
            let report = failed(
                .rejected,
                detail: error.localizedDescription,
                host: handshake.host,
                elapsed: Date().timeIntervalSince(started)
            )
            store(report)
            return report
        }

        let containers = apps.compactMap { $0.container }
        let report = RemoteProbeReport(
            state: apps.isEmpty ? .empty : .ok,
            appCount: apps.count,
            containerCount: containers.count,
            host: handshake.host,
            detail: apps.isEmpty ? "Browse 返回 0 条（可能被按身份过滤）" : "installation_proxy 正常",
            elapsed: Date().timeIntervalSince(started)
        )
        store(report, apps: apps)
        return report
    }

    /// 上次探测结果，不重新握手。
    var latestReport: RemoteProbeReport? {
        lock.lock()
        defer { lock.unlock() }
        return lastReport
    }

    /// 按 bundleID 找容器路径（走缓存，O(1)）。
    func container(for bundleID: String) -> String? {
        guard let apps = cachedApps() else { return nil }
        return apps.first { $0.bundleID == bundleID }?.container
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Keys.apps)
        UserDefaults.standard.removeObject(forKey: Keys.updatedAt)
        lock.lock()
        lastReport = nil
        lastFailureAt = nil
        lock.unlock()
    }

    // MARK: - 缓存

    private func store(_ report: RemoteProbeReport, apps: [InstalledApp]? = nil) {
        lock.lock()
        lastReport = report
        if report.isUsable {
            lastFailureAt = nil
        } else {
            lastFailureAt = Date()
        }
        lock.unlock()

        guard let apps, !apps.isEmpty else { return }
        let cached = apps.map {
            CachedApp(bundleID: $0.bundleID, container: $0.container, name: $0.name)
        }
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: Keys.apps)
            UserDefaults.standard.set(Date(), forKey: Keys.updatedAt)
        }
    }

    private func failed(
        _ state: RemoteProbeReport.State,
        detail: String,
        host: String,
        elapsed: TimeInterval
    ) -> RemoteProbeReport {
        RemoteProbeReport(
            state: state,
            appCount: 0,
            containerCount: 0,
            host: host,
            detail: detail,
            elapsed: elapsed
        )
    }

    private func cachedApps() -> [CachedApp]? {
        guard let data = UserDefaults.standard.data(forKey: Keys.apps) else { return nil }
        return try? JSONDecoder().decode([CachedApp].self, from: data)
    }

    private func cachedContainers() -> [String]? {
        guard let apps = cachedApps() else { return nil }
        return apps.compactMap { $0.container }
    }
}
