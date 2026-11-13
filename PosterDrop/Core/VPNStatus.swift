//
//  VPNStatus.swift
//  PosterDrop
//
//  VPN / 隧道状态检测。
//
//  为什么不能只看网卡：
//  之前用「有没有 utun 接口」判断 VPN，误报过——LocalDevVPN 建出来的隧道
//  不一定叫 utun，而别的 App（iCloud 私密代理、部分 VPN 内核）也会建 utun。
//  所以这里以「真的能连上隧道端口」为唯一判据，网卡信息只作为解释性提示。
//
//  判据：
//    · reachable      能 TCP 连上 10.7.0.1:49152（Airlift RSD 端口）
//    · interfaceOnly  有隧道网卡，但端口拨不通（VPN 内核在跑、对端没起）
//    · off            没有隧道网卡，端口也不通
//
//  当前通道（worse_query 本地直写）不需要 VPN，这个检测只用于把状态说清楚。
//

import Foundation
import Darwin

struct VPNReport: Sendable {
    enum State: String, Sendable {
        case off
        case interfaceOnly
        case reachable
    }

    let state: State
    /// 隧道类网卡（utun / ipsec / ppp / tap）
    let interfaces: [String]
    let address: String
    let detail: String
    let elapsed: TimeInterval

    var isReachable: Bool { state == .reachable }

    var title: String {
        switch state {
        case .reachable:
            return "VPN 已连通"
        case .interfaceOnly:
            return "VPN 未连通（有隧道网卡，端口不通）"
        case .off:
            return "未检测到 VPN"
        }
    }

    /// 给日志用的一句话，带判断依据
    var logLine: String {
        let ifaces = interfaces.isEmpty ? "无隧道网卡" : interfaces.joined(separator: "/")
        return "\(title)：\(address) \(detail)，\(ifaces)，耗时 \(String(format: "%.2f", elapsed))s"
    }
}

enum VPNStatus {

    static let defaultHost = "10.7.0.1"
    static let defaultPort: UInt16 = 49152

    private static let lock = NSLock()
    private static var cachedReport: VPNReport?
    private static var cachedAt: Date?

    /// 带 5 秒缓存，避免诊断页刷新时每次都拨一次。
    static func cached(maxAge: TimeInterval = 5) -> VPNReport {
        lock.lock()
        if let report = cachedReport, let at = cachedAt, Date().timeIntervalSince(at) < maxAge {
            lock.unlock()
            return report
        }
        lock.unlock()

        let report = probe()
        lock.lock()
        cachedReport = report
        cachedAt = Date()
        lock.unlock()
        return report
    }

    static func probe(
        timeout: TimeInterval = 1.5,
        host: String = defaultHost,
        port: UInt16 = defaultPort
    ) -> VPNReport {
        let started = Date()
        let tunnels = tunnelInterfaces()
        let target = "\(host):\(port)"
        let (connected, detail) = dial(host: host, port: port, timeout: timeout)
        let elapsed = Date().timeIntervalSince(started)

        let state: VPNReport.State
        if connected {
            state = .reachable
        } else if tunnels.isEmpty {
            state = .off
        } else {
            state = .interfaceOnly
        }

        return VPNReport(
            state: state,
            interfaces: tunnels.map { $0.name },
            address: target,
            detail: detail,
            elapsed: elapsed
        )
    }

    /// 隧道类网卡及其 IPv4 地址。只作为解释信息，不单独作为「VPN 已连接」的依据。
    static func tunnelInterfaces() -> [(name: String, address: String?)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [(name: String, address: String?)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let namePointer = current.pointee.ifa_name else { continue }
            let name = String(cString: namePointer)
            let lower = name.lowercased()
            guard lower.hasPrefix("utun") || lower.hasPrefix("ipsec")
                    || lower.hasPrefix("ppp") || lower.hasPrefix("tap")
                    || lower.hasPrefix("tun") else { continue }

            var address: String?
            if let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(addr.pointee.sa_len)
                if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                }
            }

            if let index = result.firstIndex(where: { $0.name == name }) {
                if result[index].address == nil { result[index].address = address }
            } else {
                result.append((name, address))
            }
        }
        return result
    }

    /// 非阻塞 connect + poll：1.5 秒内没结果就放弃，绝不卡主线程。
    private static func dial(host: String, port: UInt16, timeout: TimeInterval) -> (Bool, String) {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let addr = info else {
            return (false, "地址无效")
        }
        defer { freeaddrinfo(info) }

        let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard fd >= 0 else { return (false, "socket 创建失败") }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        if connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
            return (true, "端口可达")
        }
        guard errno == EINPROGRESS else {
            return (false, errnoText(errno))
        }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(0.2, timeout) * 1000)
        let ready = poll(&descriptor, 1, milliseconds)
        if ready == 0 { return (false, "端口超时") }
        guard ready > 0 else { return (false, "poll 失败") }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
            return (false, "取连接状态失败")
        }
        if error == 0 { return (true, "端口可达") }
        return (false, errnoText(error))
    }

    private static func errnoText(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED: return "连接被拒绝"
        case ETIMEDOUT: return "端口超时"
        case EHOSTUNREACH: return "主机不可达"
        case ENETUNREACH: return "网络不可达"
        case ECONNRESET: return "连接被重置"
        default: return "错误 \(code)"
        }
    }
}
