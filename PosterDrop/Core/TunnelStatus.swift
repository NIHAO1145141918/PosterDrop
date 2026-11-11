//
//  TunnelStatus.swift
//  PosterDrop
//
//  Airlift 需要一条本机回环隧道（LocalDevVPN / WireGuard 回环模式，地址 10.7.0.1），
//  Rust 侧默认就是往这个地址拨号。这里枚举本机接口给出状态提示。
//

import Foundation
import Darwin

struct TunnelReport {
    var isReady: Bool
    var detail: String
    var addresses: [String]
}

enum TunnelStatus {

    static func probe() -> TunnelReport {
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
                    if name.hasPrefix("utun") || name == "lo0" || name.hasPrefix("ipsec") || name.hasPrefix("tap") || name.hasPrefix("tun") {
                        interfaces.append("\(name) = \(ip)")
                    }
                }
            }

            cursor = interface.ifa_next
        }

        let ready = interfaces.contains { $0.contains("10.7.0.1") }
        let detail = ready
            ? "已检测到回环隧道 10.7.0.1"
            : "未检测到 10.7.0.1。请先打开 LocalDevVPN（WireGuard 回环模式）并连接。"

        return TunnelReport(isReady: ready, detail: detail, addresses: interfaces)
    }
}
