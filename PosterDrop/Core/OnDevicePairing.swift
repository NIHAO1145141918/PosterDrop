//
//  OnDevicePairing.swift
//  PosterDrop
//
//  iOS 27+ 的「本机配对」：App 在本机启动 RPPairing host，
//  通过 Bonjour 广播服务，用户在「设置 › 隐私与安全性 › 开发者模式」里输入 PIN 完成配对，
//  随后 Rust 核心会落盘一份配对记录，供 Airlift 通道复用。
//
//  iOS 18–26 只能导入配对文件（SideStore / LiveContainer / 电脑端导出）。
//

import Foundation
import AirliftFFI

final class OnDevicePairing: NSObject, ObservableObject {

    static let shared = OnDevicePairing()

    @Published private(set) var isRunning = false
    @Published private(set) var pin: String?
    @Published private(set) var status: String = "未启动"
    @Published private(set) var lastError: String?

    private var netService: NetService?
    private var continuation: CheckedContinuation<String, Error>?
    private var didResolve = false

    private let keepAlive = BackgroundKeepAlive()
    private let permission = LocalNetworkPermission()

    private let hostName = "PosterDrop"
    private let hostModel = "Mac17,7"
    private let bindAddress = "0.0.0.0"

    // MARK: - 对外接口

    func startAndWait() async throws -> String {
        if isRunning {
            cancel()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.main.async {
                self.didResolve = false
                self.continuation = continuation
                self.begin()
            }
        }
    }

    func cancel() {
        stopAdvertising()
        keepAlive.stop()
        update {
            self.isRunning = false
            self.pin = nil
            self.status = "已取消"
        }
        resolve(.failure(AirliftError.failed("配对被取消")))
    }

    // MARK: - 启动

    private func begin() {
        stopAdvertising()
        keepAlive.stop()
        isRunning = true
        pin = nil
        lastError = nil
        status = "正在申请本地网络权限…"

        Task {
            let granted = await permission.request()
            guard self.isRunning else { return }

            if !granted {
                self.update {
                    self.status = "本地网络权限被拒绝，请到「设置 › PosterDrop › 本地网络」开启"
                    self.lastError = "本地网络权限被拒绝"
                }
                self.resolve(.failure(AirliftError.failed("本地网络权限被拒绝，配对无法进行。")))
                return
            }

            self.keepAlive.start()
            self.update {
                self.status = "已广播配对服务，请打开「设置 › 隐私与安全性 › 开发者模式」"
            }
            self.runHost()
        }
    }

    private func runHost() {
        let bind = bindAddress
        let name = hostName
        let model = hostModel
        let outPath = PairingStore.canonicalURL.path
        let altIRK = PairingStore.shared.storedAltIRK
        let context = Unmanaged.passUnretained(self).toOpaque()

        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()

            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            altIRK.withCString { irkC in
                                al_pairing_run_host(
                                    bindC, 0, nameC, modelC, outC, irkC,
                                    pairingReadyCallback, pairingPinCallback, context, &result
                                )
                            }
                        }
                    }
                }
            }

            var deviceName = ""
            var issuedIRK = ""
            var filePath = ""
            var errorMessage = ""

            if let pointer = result.device_name { deviceName = String(cString: pointer) }
            if let pointer = result.host_alt_irk_hex { issuedIRK = String(cString: pointer) }
            if let pointer = result.pairing_file_path { filePath = String(cString: pointer) }
            if let pointer = result.error { errorMessage = String(cString: pointer) }

            al_pairing_result_free(&result)

            if rc == 0, !issuedIRK.isEmpty {
                PairingStore.shared.storedAltIRK = issuedIRK
            }

            DispatchQueue.main.async {
                self.finish(
                    rc: rc,
                    deviceName: deviceName,
                    filePath: filePath,
                    errorMessage: errorMessage,
                    fallbackPath: outPath
                )
            }
        }
    }

    private func finish(rc: Int32, deviceName: String, filePath: String, errorMessage: String, fallbackPath: String) {
        stopAdvertising()

        // 用户从“设置”返回前别被系统挂起
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.keepAlive.stop()
        }

        isRunning = false
        pin = nil

        guard rc == 0 else {
            let message = errorMessage.isEmpty ? "配对失败（错误码 \(rc)）" : errorMessage
            status = "配对失败：\(message)"
            lastError = message
            resolve(.failure(AirliftError.failed(message)))
            return
        }

        let path = filePath.isEmpty ? fallbackPath : filePath
        let size = PairingStore.fileSize(at: URL(fileURLWithPath: path))

        guard size > 0 else {
            status = "配对未完成：配对文件为空"
            lastError = "配对文件为空，请重试并确认已在设置里通过 PIN"
            resolve(.failure(AirliftError.failed("配对文件为空，请确认已在设置里通过 PIN 验证。")))
            return
        }

        // 统一落到规范路径
        if path != PairingStore.canonicalURL.path {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                try? data.write(to: PairingStore.canonicalURL, options: .atomic)
            }
        }

        let finalSize = PairingStore.fileSize(at: PairingStore.canonicalURL)
        status = "配对成功：\(deviceName.isEmpty ? "本机" : deviceName)（\(finalSize) 字节）"
        resolve(.success(PairingStore.canonicalURL.path))
    }

    // MARK: - Bonjour

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(domain: "", type: "_remotepairing-pairable-host._tcp.", name: serviceID, port: port)
        _ = service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = self
        service.publish()
        netService = service
        status = "正在广播配对服务…"
    }

    fileprivate func presentPin(_ value: String) {
        pin = value
        status = "在「设置 › 隐私与安全性 › 开发者模式 › 与 PosterDrop 配对」中输入 \(value)"
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    // MARK: - 状态与回调

    private func update(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func resolve(_ result: Result<String, Error>) {
        guard let continuation = continuation, !didResolve else { return }
        didResolve = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

// MARK: - C 回调

private let pairingReadyCallback: ALPairReadyCb = { context, serviceID, port, keys, values, count in
    guard let context = context, let serviceID = serviceID else { return }
    let controller = Unmanaged<OnDevicePairing>.fromOpaque(context).takeUnretainedValue()
    let identifier = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys = keys, let values = values {
        for index in 0..<Int(count) {
            guard let key = keys[index], let value = values[index] else { continue }
            txt[String(cString: key)] = Data(String(cString: value).utf8)
        }
    }

    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: identifier, port: Int32(port), txt: txt)
    }
}

private let pairingPinCallback: ALPairPinCb = { pinPointer, context in
    guard let pinPointer = pinPointer, let context = context else { return }
    let controller = Unmanaged<OnDevicePairing>.fromOpaque(context).takeUnretainedValue()
    let value = String(cString: pinPointer)

    DispatchQueue.main.async {
        controller.presentPin(value)
    }
}

// MARK: - Bonjour 状态反馈

extension OnDevicePairing: NetServiceDelegate {

    func netServiceDidPublish(_ sender: NetService) {
        status = "配对服务已发布，请到「设置 › 隐私与安全性 › 开发者模式 › 与 PosterDrop 配对」"
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        lastError = "Bonjour 广播失败（\(code)）"
        status = "配对服务广播失败，请检查「设置 › PosterDrop › 本地网络」后重试"
    }
}
