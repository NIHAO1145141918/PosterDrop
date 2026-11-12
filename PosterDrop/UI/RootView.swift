//
//  RootView.swift
//  PosterDrop
//
//  两个页签 + 全局 respring 遮罩。
//

import SwiftUI

struct RootView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: Int = 0

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad 全屏 / 宽分屏：侧边栏，横屏时不用在顶部横条和内容之间来回挪眼。
                tabs
                    .tabViewStyle(.sidebarAdaptable)
            } else {
                // iPhone、iPad 窄分屏、Slide Over：标准底部标签栏。
                tabs
            }
        }
        .tint(Theme.accent)
        .overlay {
            if model.isRespringing {
                RespringOverlay()
                    .transition(.opacity)
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            LibraryView()
                .tabItem {
                    Label("壁纸", systemImage: "photo.stack")
                }
                .tag(0)

            DiagnosticsView()
                .tabItem {
                    Label("诊断", systemImage: "wrench.and.screwdriver")
                }
                .tag(1)
        }
    }
}

struct RespringOverlay: View {

    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 2)
                        .frame(width: 76, height: 76)
                        .scaleEffect(pulse ? 1.15 : 0.9)
                        .opacity(pulse ? 0.2 : 0.7)

                    Image(systemName: "bolt.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accentGradient)
                }

                VStack(spacing: 6) {
                    Text("正在重启桌面")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text("壁纸已写入，SpringBoard 重新加载后即可在墙纸里选用")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
