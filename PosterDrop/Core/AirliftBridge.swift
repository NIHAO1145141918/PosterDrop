//
//  AirliftBridge.swift
//  PosterDrop
//
//  AirliftFFI（Rust 核心）的 Swift 封装：
//  配对 → 建立到系统内部服务的回环通道 → 目录注入 / 容器查询 / 重启桌面。
//
//  Rust 侧的 C 接口见 Vendor/AirliftFFI.xcframework/.../Headers/airlift.h
//

import Foundation
import AirliftFFI

enum AirliftError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

/// Rust 侧全局日志回调。必须是非捕获闭包，才能转成 C 函数指针。
let airliftLogCallback: ALLogCallback = { _, messagePointer in
    guard let messagePointer = messagePointer else { return }
    let line = String(cString: messagePointer)
    LogBus.shared.append(line)
}

enum Airlift {

    private static var didBootstrap = false

    /// 安装全局日志订阅、设置默认隧道地址。启动时调用一次即可。
    static func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        _ = al_log_init(airliftLogCallback, nil)
        // LocalDevVPN 回环隧道地址；未连接时调用会自然失败并给出可读错误。
        setTargetHost("10.7.0.1")
    }

    static func setTargetHost(_ host: String) {
        _ = host.withCString { pointer in
            al_set_target_host(pointer)
        }
    }

    /// 解压 zip（.tendies 本质就是 zip）。返回 0 表示成功。
    @discardableResult
    static func extractZip(archive: String, into destination: String) -> Int32 {
        return archive.withCString { archiveC in
            destination.withCString { destinationC in
                al_zip_extract_all(archiveC, destinationC)
            }
        }
    }

    /// 查询指定 bundle id 的数据容器真实路径（例如 com.apple.PosterBoard）。
    static func findContainer(pairingPath: String, bundleID: String) throws -> String {
        var outContainer: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { pairingC in
            bundleID.withCString { bundleC in
                al_find_app_container(pairingC, bundleC, airliftLogCallback, nil, &outContainer, &outError)
            }
        }

        if rc == 0, let containerPointer = outContainer {
            let container = String(cString: containerPointer)
            al_string_free(containerPointer)
            if let errorPointer = outError { al_string_free(errorPointer) }
            return container
        }

        let message = outError.map { String(cString: $0) } ?? "无法定位 \(bundleID) 的数据容器（错误码 \(rc)）"
        if let containerPointer = outContainer { al_string_free(containerPointer) }
        if let errorPointer = outError { al_string_free(errorPointer) }
        throw AirliftError.failed(message)
    }

    /// 把本地目录里的所有文件写进设备上的目标目录。
    static func writeDirectory(pairingPath: String, source: String, target: String) throws {
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { pairingC in
            source.withCString { sourceC in
                target.withCString { targetC in
                    al_exploit_write_dir(pairingC, sourceC, targetC, airliftLogCallback, nil, &outError)
                }
            }
        }

        if rc != 0 {
            let message = outError.map { String(cString: $0) } ?? "写入 \(target) 失败（错误码 \(rc)）"
            if let errorPointer = outError { al_string_free(errorPointer) }
            throw AirliftError.failed(message)
        }
        if let errorPointer = outError { al_string_free(errorPointer) }
    }

    /// 把一整个目录（含内部资源）原子注入到 targetParentDir/destName。
    static func injectFolder(pairingPath: String, folder: String, parent: String, destName: String) throws {
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { pairingC in
            folder.withCString { folderC in
                parent.withCString { parentC in
                    destName.withCString { destC in
                        al_exploit_inject_folder(pairingC, folderC, parentC, destC, airliftLogCallback, nil, &outError)
                    }
                }
            }
        }

        if rc != 0 {
            let message = outError.map { String(cString: $0) } ?? "注入 \(destName) 失败（错误码 \(rc)）"
            if let errorPointer = outError { al_string_free(errorPointer) }
            throw AirliftError.failed(message)
        }
        if let errorPointer = outError { al_string_free(errorPointer) }
    }

    /// 通过诊断中继让设备重启桌面（不重启系统）。
    @discardableResult
    static func respringDevice(pairingPath: String) -> Bool {
        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { pairingC in
            al_device_respring(pairingC, airliftLogCallback, nil, &outError)
        }
        if let errorPointer = outError { al_string_free(errorPointer) }
        return rc == 0
    }
}
