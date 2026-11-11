//
//  PosterDropApp.swift
//  PosterDrop
//

import SwiftUI
import UIKit

@main
struct PosterDropApp: App {

    @StateObject private var model = AppModel()

    init() {
        Airlift.bootstrap()
        LogBus.shared.append("PosterDrop 启动")
        LogBus.shared.append("系统版本：iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in
                    model.handleIncoming(url: url)
                }
                .onAppear {
                    model.refreshPairingState()
                }
        }
    }
}
