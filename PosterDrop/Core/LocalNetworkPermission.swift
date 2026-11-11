//
//  LocalNetworkPermission.swift
//  PosterDrop
//
//  触发/查询本地网络权限。iOS 只会在真正发起 Bonjour 浏览时弹窗，
//  这里用一个专用探测服务名来触发，超时则视为“未明确拒绝”，交给后续配对流程判断。
//

import Foundation
import Network

final class LocalNetworkPermission {

    private let queue = DispatchQueue(label: "com.posterdrop.localnetwork")

    func request(timeout: TimeInterval = 10) async -> Bool {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var finished = false

            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: "_posterdrop-probe._tcp", domain: nil), using: parameters)

            func finish(_ granted: Bool) {
                guard !finished else { return }
                finished = true
                browser.cancel()
                continuation.resume(returning: granted)
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed:
                    finish(false)
                default:
                    break
                }
            }

            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(true)
            }
        }
    }
}
