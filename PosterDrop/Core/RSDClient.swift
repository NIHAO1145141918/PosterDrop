//
//  RSDClient.swift
//  PosterDrop
//
//  RSD（Remote Service Discovery）客户端。iOS 17+ 上所有开发者服务
//  （installation_proxy / afc / diagnostics）都挂在它后面。
//
//  协议三层：
//    1. TCP 到设备侧端口（LocalDevVPN 把 10.7.0.1:49152 送到本机
//       remotepairingd，或者直接连局域网 IP）
//    2. TLS，客户端证书取自配对记录里的 HostCertificate + HostPrivateKey
//    3. 4 字节大端长度 + plist(XML) 的帧：先 Checkin，拿到服务表
//
//  这里只做「读到服务表」为止。具体服务由 InstallationProxy 接管。
//
//  为什么不用 Airlift 的 Rust 静态库：
//  它只暴露 `al_find_app_container`（一次一个 bundleID），而我们手上
//  没有 bundleID 清单（class 13 返回 0）。要一次拿全量列表，必须自己
//  发 installation_proxy 的 Browse，所以这段只能用 Swift 重写。
//

import Foundation
import Network
import Security

enum RSDError: LocalizedError {
    case pairing(String)
    case connect(String)
    case tls(String)
    case protocolViolation(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .pairing(message): return message
        case let .connect(message): return "连接失败：\(message)"
        case let .tls(message): return "TLS 握手失败：\(message)"
        case let .protocolViolation(message): return "协议错误：\(message)"
        case let .timeout(message): return "超时：\(message)"
        }
    }
}

/// Checkin 的结果：服务名 → (端口, 是否加密)
struct RSDHandshake {
    let host: String
    let port: UInt16
    let services: [String: RSDService]
    let serverInfo: [String: Any]

    struct RSDService {
        let port: UInt16
        let usesTLS: Bool
    }

    func service(_ name: String) -> RSDService? {
        services[name]
    }

    var serviceNames: [String] {
        services.keys.sorted()
    }
}

final class RSDClient {

    static let defaultHost = "10.7.0.1"
    static let defaultPort: UInt16 = 49152

    // MARK: - 入口

    /// 握手一次，拿到服务表。`host` 为 nil 时按「隧道地址 → 局域网 mDNS」顺序试。
    static func handshake(
        host: String? = nil,
        port: UInt16 = defaultPort,
        timeout: TimeInterval = 8,
        log: (String) -> Void = { _ in }
    ) throws -> RSDHandshake {
        let pairing = try PairingStore.shared.record()
        let identity = try PairingStore.identity(for: pairing)

        // 候选地址：显式指定 > 隧道 > mDNS 找到的局域网地址
        var candidates: [(String, UInt16)] = []
        if let host, !host.isEmpty {
            candidates.append((host, port))
        } else {
            candidates.append((defaultHost, defaultPort))
            if let discovered = discoverViaBonjour(timeout: 3) {
                candidates.append(discovered)
            }
        }

        var lastError: Error = RSDError.connect("没有可用的候选地址")
        for (candidateHost, candidatePort) in candidates {
            do {
                log("RSD 尝试 \(candidateHost):\(candidatePort)…")
                return try checkin(
                    host: candidateHost,
                    port: candidatePort,
                    identity: identity,
                    timeout: timeout,
                    log: log
                )
            } catch {
                lastError = error
                log("   \(candidateHost):\(candidatePort) 不通：\(error.localizedDescription)")
            }
        }
        throw lastError
    }

    // MARK: - Checkin

    private static func checkin(
        host: String,
        port: UInt16,
        identity: SecIdentity,
        timeout: TimeInterval,
        log: (String) -> Void
    ) throws -> RSDHandshake {
        let link = try RSDLink(host: host, port: port, identity: identity, timeout: timeout)
        defer { link.close() }

        var sessionBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, sessionBytes.count, &sessionBytes)

        let request: [String: Any] = [
            "Label": "PosterDrop",
            "ProtocolVersion": "1.0.0",
            "HostOptions": [
                "HeartbeatInterval": 5.0,
                "SessionId": Data(sessionBytes)
            ]
        ]

        let payload = try PropertyListSerialization.data(
            fromPropertyList: request, format: .xml, options: 0
        )
        // 4 字节大端长度前缀
        var framed = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)

        try link.send(framed)
        log("   已发送 Checkin，等待服务表…")

        let header = try link.readExactly(4, timeout: timeout)
        let size = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard size > 0, size < 8 * 1024 * 1024 else {
            throw RSDError.protocolViolation("响应长度异常：\(size)")
        }
        let body = try link.readExactly(Int(size), timeout: timeout)

        guard let plist = try? PropertyListSerialization.propertyList(
            from: body, options: [], format: nil
        ), let dictionary = plist as? [String: Any] else {
            throw RSDError.protocolViolation("Checkin 响应不是 plist")
        }

        // 出错时服务端会给 Error / Message
        if let message = dictionary["Error"] as? String {
            throw RSDError.tls("设备拒绝握手：\(message)")
        }

        guard let rawServices = dictionary["Services"] as? [String: Any], !rawServices.isEmpty else {
            // 有些实现把服务放在 PeerInfo 里
            throw RSDError.protocolViolation("响应里没有 Services（可能配对文件不被这台设备认可）")
        }

        var services: [String: RSDHandshake.RSDService] = [:]
        for (name, value) in rawServices {
            guard let entry = value as? [String: Any] else { continue }
            guard let rawPort = entry["Port"] as? Int, rawPort > 0, rawPort <= 65_535 else { continue }
            // 字段可能不存在；不存在时按加密处理（iOS 17+ 默认全加密）
            let usesTLS = (entry["EnableServiceSSL"] as? Bool) ?? true
            services[name] = RSDHandshake.RSDService(
                port: UInt16(rawPort),
                usesTLS: usesTLS
            )
        }

        guard !services.isEmpty else {
            throw RSDError.protocolViolation("Services 里没有可用端口")
        }

        return RSDHandshake(
            host: host,
            port: port,
            services: services,
            serverInfo: dictionary
        )
    }

    // MARK: - mDNS

    /// RSD 通过 `_remotepairing._tcp` 广播，地址是设备自己的局域网 IP。
    /// 这条路径不需要 VPN——只要手机连着 WiFi、并且 App 有本地网络权限。
    static func discoverViaBonjour(timeout: TimeInterval) -> (String, UInt16)? {
        let semaphore = DispatchSemaphore(value: 0)

        final class Box: @unchecked Sendable {
            var host: String?
            var port: UInt16 = 0
        }
        let box = Box()
        let lock = NSLock()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_remotepairing._tcp", domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { state in
            if case .failed = state { semaphore.signal() }
            if case .cancelled = state { semaphore.signal() }
        }

        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, _, domain, _) = result.endpoint else { continue }
                // 解析成 IP：再做一次 connect 太重，这里先让 Network 解析端点。
                // 简化处理：用 Bonjour 服务名交给 NWConnection 直接连，地址由系统解析。
                lock.lock()
                if box.host == nil {
                    box.host = domain.isEmpty ? "\(name).local" : "\(name).\(domain)"
                }
                lock.unlock()
                break
            }
            semaphore.signal()
        }

        browser.start(queue: .global(qos: .utility))
        _ = semaphore.wait(timeout: .now() + timeout)
        browser.cancel()

        lock.lock()
        defer { lock.unlock() }
        guard let host = box.host else { return nil }
        return (host, defaultPort)
    }
}

// MARK: - 同步连接封装

/// NWConnection 是异步的，这里包成「读够 N 字节或超时」的同步接口。
// 叫 RSDLink 而不是 Link：SwiftUI 有个同名视图，避免哪天同文件 import SwiftUI 撞上。
/// 只在本类的局部生命周期内使用，用完即 close。
final class RSDLink {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let condition = NSCondition()
    private let ready = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var closed = false
    private var failure: String?
    private let timeout: TimeInterval

    init(host: String, port: UInt16, identity: SecIdentity?, timeout: TimeInterval) throws {
        self.timeout = timeout

        // 用局部变量而不是 self.queue：此刻 connection 还没赋值，
        // Swift 不允许在所有 stored property 初始化前访问 self。
        let linkQueue = DispatchQueue(label: "posterdrop.rsd.link")
        self.queue = linkQueue

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        if let identity, let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        }
        // 设备是自签证书，链式校验必然失败；身份由 pairing record 保证，
        // 这里只确认「对方持有对应私钥」（TLS 握手本身会验签）。
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            linkQueue
        )

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw RSDError.connect("端口无效：\(port)")
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: parameters
        )

        // 到这里所有 stored property 都有值，才能把 self 交给回调
        attachHandlers()
        connection.start(queue: linkQueue)

        if ready.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw RSDError.timeout("连接 \(host):\(port) 超时")
        }

        condition.lock()
        let failed = failure
        condition.unlock()
        if let failed {
            connection.cancel()
            throw RSDError.connect(failed)
        }

        startReceiving()
    }

    private func attachHandlers() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready.signal()
            case let .failed(error):
                self.condition.lock()
                self.failure = "\(error)"
                self.closed = true
                self.condition.broadcast()
                self.condition.unlock()
                self.ready.signal()
            case .cancelled:
                self.condition.lock()
                self.closed = true
                self.condition.broadcast()
                self.condition.unlock()
                self.ready.signal()
            default:
                break
            }
        }
    }

    private func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.condition.lock()
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            if let error {
                self.failure = "\(error)"
                self.closed = true
            } else if isComplete {
                self.failure = self.failure ?? "对端关闭连接"
                self.closed = true
            }
            self.condition.broadcast()
            self.condition.unlock()

            if error == nil && !isComplete {
                self.startReceiving()
            }
        }
    }

    func send(_ data: Data) throws {
        let box = SendBox()
        let done = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { error in
            box.error = error.map { "\($0)" }
            done.signal()
        })
        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw RSDError.timeout("发送超时")
        }
        if let message = box.error {
            throw RSDError.connect(message)
        }
    }

    func readExactly(_ count: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while buffer.count < count {
            if closed {
                throw RSDError.connect(failure ?? "连接已关闭")
            }
            if !condition.wait(until: deadline) && buffer.count < count {
                throw RSDError.timeout("等待 \(count) 字节超时（已有 \(buffer.count)）")
            }
        }

        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }

    /// 读到至少 `count` 字节，或者等到出现 `marker`。用于没有长度前缀的服务。
    func readUntil(marker: Data, timeout: TimeInterval, maximum: Int = 16 * 1024 * 1024) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            if let range = buffer.range(of: marker) {
                let end = range.upperBound
                let data = buffer.prefix(end)
                buffer.removeFirst(end)
                return Data(data)
            }
            if buffer.count > maximum {
                throw RSDError.protocolViolation("响应超过上限 \(maximum) 字节")
            }
            if closed {
                // 关闭前可能刚好收全，再查一次
                if let range = buffer.range(of: marker) {
                    let data = buffer.prefix(range.upperBound)
                    buffer.removeFirst(range.upperBound)
                    return Data(data)
                }
                throw RSDError.connect(failure ?? "连接已关闭")
            }
            if !condition.wait(until: deadline) {
                if let range = buffer.range(of: marker) {
                    let data = buffer.prefix(range.upperBound)
                    buffer.removeFirst(range.upperBound)
                    return Data(data)
                }
                throw RSDError.timeout("等待响应超时（已收 \(buffer.count) 字节）")
            }
        }
    }

    func close() {
        connection.cancel()
    }
}

/// `contentProcessed` 的回调在 Network 的队列上跑，用盒子避免
/// 「逃逸闭包修改局部变量」的并发告警。
private final class SendBox: @unchecked Sendable {
    var error: String?
}
