//
//  DiagnosticsView.swift
//  PosterDrop
//
//  诊断页：容器探测、注入参数、缓存刷新、respring、运行日志。
//

import SwiftUI
import UIKit

struct DiagnosticsView: View {

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var logBus = LogBus.shared

    @State private var copiedHint: String?
    @State private var vpnReport: VPNReport?
    @State private var vpnChecking = false
    @State private var showingPairing = false
    @State private var remoteReport: RemoteProbeReport?

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        if let banner = model.banner {
                            BannerView(banner: banner) {
                                model.banner = nil
                            }
                        }

                        containerCard
                        directCard
                        optionsCard
                        remoteCard
                        actionsCard
                        logCard
                        aboutCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                    .readableColumn(820)
                }
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPairing) {
                PairingSheet()
            }
            .onAppear { remoteReport = RemoteContainerIndex.shared.latestReport }
            .overlay(alignment: .top) {
                if let hint = copiedHint {
                    Text(hint)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - 容器

    private var containerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PosterBoard 容器")
                .font(.subheadline.weight(.semibold))

            Text(model.containerPath.isEmpty
                 ? "尚未探测。点「自动探测」定位 PosterBoard 的数据容器；自动定位失败时，可从这里粘贴路径。"
                 : "当前使用的容器路径。可以直接编辑或粘贴新路径。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("/var/mobile/Containers/Data/Application/<UUID>", text: $model.containerPath)
                .font(.system(size: 11, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            HStack(spacing: 10) {
                Button {
                    Task { await model.detectContainer() }
                } label: {
                    Label("自动探测", systemImage: "location.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.isWorking)

                Button {
                    UIPasteboard.general.string = model.containerPath
                    flashHint("已复制容器路径")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(height: 42)
                }
                .buttonStyle(.bordered)
                .disabled(model.containerPath.isEmpty)
            }

            Text("容器路径形如 /var/mobile/Containers/Data/Application/<UUID>。自动探测会用 fsgetpath 把容器目录里的 UUID 反查出来（不需要 VPN，也不需要读目录权限），再批量认领 bundle id。第一次扫一遍卷要几秒，之后走缓存 + 增量，通常一秒内；定位成功过的路径会直接命中。如果还是失败，去 WQFiles 的「App Data › PosterBoard」长按复制路径粘贴到上面。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    // MARK: - VPN 状态

    /// 只报告真实状态：以「能不能连上 10.7.0.1:49152」为准，
    /// 有 utun 网卡但端口不通会明确写成「未连通」，不再误判。
    private var vpnRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(vpnColor)
                    .frame(width: 8, height: 8)
                Text(vpnReport?.title ?? "VPN 状态未检测")
                    .font(.caption.weight(.medium))
                Spacer()
                Button {
                    checkVPN()
                } label: {
                    if vpnChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("检测")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
                .disabled(vpnChecking)
            }

            if let report = vpnReport {
                Text("\(report.address) \(report.detail) · 隧道网卡 \(report.interfaces.isEmpty ? "无" : report.interfaces.joined(separator: "/")) · \(String(format: "%.2f", report.elapsed))s")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("当前通道是本地直写，不需要 VPN；这里只是把真实状态说清楚。VPN 开着也不会更快——隧道要多绕一次本机 loopback。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .onAppear { if vpnReport == nil { checkVPN() } }
    }

    private var vpnColor: Color {
        guard let state = vpnReport?.state else { return .secondary }
        switch state {
        case .reachable: return .green
        case .interfaceOnly: return .orange
        case .off: return .secondary
        }
    }

    private func checkVPN() {
        guard !vpnChecking else { return }
        vpnChecking = true
        Task {
            let report = await Task.detached(priority: .userInitiated) { VPNStatus.probe() }.value
            vpnReport = report
            vpnChecking = false
        }
    }

    // MARK: - 直连通道

    private var directCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("沙箱通道 · worse_query")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("唯一底层")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.accent)
            }

            Text("worse_query：把 App Group 容器的 Library/Caches 换成指向目标目录的符号链接，再让 containermanagerd 为它签发沙箱扩展。拿到扩展后直接用文件 API 读写 PosterBoard 容器，不经过配对、RSD 或任何 VPN。支持 iOS 26.0–26.7.2 / 27.2。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("App Group（留空则读签名）", text: $model.appGroupID)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            Text("必须有 App Groups 权限：containermanagerd 只对 App Group 容器返回结果。留空会自动读取签名里的 com.apple.security.application-groups；重签时在「轻松签 / ESign → App Groups」里勾一个 group 即可，免费 Personal Team 通常也能签发。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            vpnRow

            Button {
                Task { await model.probeDirectChannel() }
            } label: {
                Label("自检通道", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(model.isWorking)

            if !model.directStatus.isEmpty {
                Text(model.directStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
        }
        .card()
    }

    // MARK: - 远程索引

    /// 配对 + RSD 是可选的快路径：通了就把 250 秒的 inode 扫描换成 1 秒的
    /// installation_proxy，不通也不影响现有任何功能，所以这里不报红字。
    private var remoteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("远程索引（可选）")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(PairingStore.shared.hasPairing ? "已导入" : "未启用")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(PairingStore.shared.hasPairing ? .green : .secondary)
            }

            Text(PairingStore.shared.hasPairing
                 ? "通过配对文件走 RSD，一次拿到全部 App 的容器路径，跳过整卷扫描。"
                 : "导入一份和本机配过对的 pairing 记录，清理时就不用再扫 1.2 亿个 inode。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let report = remoteReport {
                HStack(spacing: 12) {
                    Text(report.state.rawValue)
                        .font(.caption.weight(.medium))
                    if report.isUsable {
                        Text("\(report.appCount) App / \(report.containerCount) 容器")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.2fs", report.elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            Button {
                showingPairing = true
            } label: {
                Label(PairingStore.shared.hasPairing ? "管理配对文件" : "导入配对文件",
                      systemImage: "key.horizontal")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .card()
    }

    // MARK: - 选项

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("注入参数")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("结构版本 \(model.effectiveStructVersion)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.accent)
            }

            Toggle(isOn: $model.autoStructVersion) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动选择数据结构版本")
                        .font(.footnote.weight(.medium))
                    Text("新结构用 61，旧结构用 59")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Theme.accent)

            if !model.autoStructVersion {
                Picker("结构版本", selection: $model.manualStructVersion) {
                    Text("59（旧结构）").tag(59)
                    Text("61（新结构，默认）").tag(61)
                }
                .pickerStyle(.segmented)
            }

            Divider().opacity(0.4)

            Toggle(isOn: $model.resetProtections) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("强制刷新 PosterBoard 缓存")
                        .font(.footnote.weight(.medium))
                    Text("重置文件保护标记，让系统立即重新索引壁纸")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Theme.accent)

            Toggle(isOn: $model.dualInject) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同时写入新容器（iOS 26+）")
                        .font(.footnote.weight(.medium))
                    Text("额外写一份 .Posters.<Name>App，壁纸更容易出现在“墙纸”里")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Theme.accent)
        }
        .card()
    }

    // MARK: - 操作

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("维护操作")
                .font(.subheadline.weight(.semibold))

            actionButton(title: "刷新壁纸缓存", subtitle: "壁纸已注入但不显示时使用", symbol: "arrow.triangle.2.circlepath", tint: Theme.accent) {
                Task { await model.refreshCacheOnly() }
            }

            actionButton(title: "重启桌面（NeoSpring）", subtitle: "最快，通常 1~2 秒恢复", symbol: "bolt.fill", tint: .orange) {
                model.respringManually()
            }

            actionButton(title: "打开系统墙纸设置", subtitle: "注入完成后直接挑选壁纸", symbol: "photo.on.rectangle.angled", tint: .green) {
                Respring.openWallpaperSettings()
            }
        }
        .card()
    }

    private func actionButton(title: String, subtitle: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
    }

    // MARK: - 日志

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("运行日志")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(logBus.lines.count) 行")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button {
                    UIPasteboard.general.string = logBus.exportText()
                    flashHint("日志已复制")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(logBus.lines.isEmpty)

                Button {
                    logBus.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(logBus.lines.isEmpty)
            }

            LogConsoleView(lines: logBus.lines)
                .frame(height: DeviceLabel.isPad ? 320 : 220)
        }
        .card()
    }

    // MARK: - 关于

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关于")
                .font(.subheadline.weight(.semibold))

            InfoRow(title: "版本", value: appVersion)
            InfoRow(title: "适配", value: DeviceLabel.isPad ? "iPadOS 26.0 – 27.2" : "iOS 26.0 – 27.2")
            InfoRow(
                title: "当前系统",
                value: "iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)"
                    + (AppModel.osSupport.ok ? "" : "（不在支持范围）")
            )
            InfoRow(title: "设备", value: DeviceLabel.isPad ? "iPad · 支持分屏与台前调度" : "iPhone")
            InfoRow(title: "底层", value: "worse_query（App Group 沙箱扩展）", monospaced: true)

            Text("本工具只做壁纸包的导入与注入，不修改系统 App 的身份或账户信息。写入系统目录属于非官方能力，Apple 可能随时在系统更新中修复 worse_query 的符号链接签发缺陷。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("请仅在你自己拥有或获授权管理的设备上使用，操作前务必备份重要数据。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func flashHint(_ text: String) {
        withAnimation { copiedHint = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { copiedHint = nil }
        }
    }
}
