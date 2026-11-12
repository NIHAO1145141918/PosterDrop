//
//  TunnelStatus.swift
//  PosterDrop
//
//  Airlift 需要一条本机回环隧道（LocalDevVPN / WireGuard 回环模式，地址 10.7.0.1），
//  Rust 侧默认就是往这个地址拨号。
//
//  检测分两级：
//    ① 看本机有没有 10.7.0.1 的接口地址 —— 快，但很多隧道实现不会把地址挂在 utun 上；
//    ② 真的往 10.7.0.1:49152 拨一次 TCP（Airlift 用的 RSD 端口）—— 这才是“能不能用”的证据。
//
//  之前只做了 ①，导致 VPN 明明连着、Airlift 也能连上，界面却显示“未检测到隧道”。
//

import Foundation
import Darwin
import Network

struct TunnelReport {
    var isReady: Bool
    var detail: String
    var addresses: [String]
}

enum TunnelStatus {

    /// RSD 服务端口（Airlift 拨的端口）
    static let probePort: UInt16 = 49152

    // MARK: - 接口层（同步、零副作用）

    static func probeInterfaces() -> TunnelReport {
        var interfaces: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&head) == 0, let first = head else {
            return TunnelReport(isReady: false, detail: "无法读取本机网络接口", addresses: [])
        }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let interface = pointer.pointee

            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    address,
                    socklen_t(address.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let name = String(cString: interface.ifa_name)
                    let ip = String(cString: host)
                    if name.hasPrefix("utun") || name == "lo0" || name.hasPrefix("ipsec")
                        || name.hasPrefix("tap") || name.hasPrefix("tun") {
                        interfaces.append("\(name) = \(ip)")
                    }
                }
            }

            cursor = interface.ifa_next
        }

        let hasAddress = interfaces.contains { $0.contains("10.7.0.1") }
        return TunnelReport(
            isReady: hasAddress,
            detail: hasAddress ? "已检测到回环接口 10.7.0.1" : "本机接口里没有 10.7.0.1",
            addresses: interfaces
        )
    }

    /// 兼容旧调用
    static func probe() -> TunnelReport {
        return probeInterfaces()
    }

    // MARK: - 连通性（异步、真实拨号）

    /// 先看接口，再看能不能真的连上 10.7.0.1:49152。
    static func probeConnectivity(timeout: TimeInterval = 2.0,
                                  completion: @escaping (TunnelReport) -> Void) {
        let interfaceReport = probeInterfaces()

        connect(host: "10.7.0.1", port: probePort, timeout: timeout) { reachable in
            var report = interfaceReport
            if reachable {
                report.isReady = true
                report.detail = "隧道可用：10.7.0.1:\(probePort) 已连通"
            } else if interfaceReport.isReady {
                report.isReady = true
                report.detail = "接口里有 10.7.0.1，但 \(probePort) 没响应（服务可能还没起）"
            } else {
                report.isReady = false
                report.detail = "连不上 10.7.0.1:\(probePort)。请先打开 LocalDevVPN（回环模式）并连接；已连接的话稍等一下再点刷新。"
            }
            DispatchQueue.main.async { completion(report) }
        }
    }

    private static func connect(host: String, port: UInt16, timeout: TimeInterval,
                                completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(false)
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "posterdrop.tunnel.probe")
        let lock = NSLock()
        var finished = false

        func finish(_ ok: Bool) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            connection.cancel()
            completion(ok)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .waiting:
                finish(false)
            case .cancelled:
                finish(false)
            default:
                break
            }
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(false)
        }
    }
}
