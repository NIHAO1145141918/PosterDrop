//
//  PairingView.swift
//  PosterDrop
//
//  配对管理：导入配对文件 / 本机配对（iOS 27+）/ 隧道状态。
//

import SwiftUI
import UniformTypeIdentifiers

struct PairingView: View {

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var pairing = OnDevicePairing.shared

    @State private var showImporter = false
    @State private var tunnelReport: TunnelReport?
    @State private var candidates: [PairingCandidate] = []
    @State private var isPairing = false
    @State private var showDeleteConfirm = false

    private var pairingTypes: [UTType] {
        var types: [UTType] = []
        if let custom = UTType("com.posterdrop.pairing") {
            types.append(custom)
        }
        types.append(contentsOf: [.propertyList, .xml, .data])
        return types
    }

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

                        statusCard
                        onDeviceCard
                        importCard

                        if !candidates.isEmpty {
                            candidatesCard
                        }

                        guideCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { refresh() }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: pairingTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        model.importPairing(from: url)
                        refresh()
                    }
                case .failure(let error):
                    model.banner = .error("选择配对文件失败：\(error.localizedDescription)")
                }
            }
            .confirmationDialog("删除本机保存的配对凭据？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    model.deletePairing()
                    refresh()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("删除后需要重新导入或重新本机配对。")
            }
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill((model.hasPairing ? Color.green : Color.orange).opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: model.hasPairing ? "checkmark.seal.fill" : "exclamationmark.seal")
                        .foregroundColor(model.hasPairing ? .green : .orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.hasPairing ? "配对记录已就绪" : "缺少配对记录")
                        .font(.subheadline.weight(.semibold))
                    Text(model.hasPairing ? "\(model.pairingSize) 字节" : "从 SideStore / 电脑导入，或本机配对")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            Divider().opacity(0.4)

            InfoRow(title: "配对文件", value: "pairing.plist", monospaced: true)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: (tunnelReport?.isReady ?? false) ? "bolt.horizontal.circle.fill" : "bolt.slash")
                    .font(.caption)
                    .foregroundColor((tunnelReport?.isReady ?? false) ? .green : .orange)
                Text(tunnelReport?.detail ?? "正在检测回环隧道…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let report = tunnelReport, !report.addresses.isEmpty {
                Text(report.addresses.joined(separator: "   "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.hasPairing {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除配对凭据", systemImage: "trash")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .card()
    }

    // MARK: - 本机配对

    private var onDeviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.and.arrow.forward")
                    .foregroundStyle(Theme.accentGradient)
                Text("本机配对（iOS 27 及以上）")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("无需电脑")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                    .foregroundColor(Theme.accent)
            }

            Text("App 会广播一个一次性配对服务，你在“设置 › 隐私与安全性 › 开发者模式”里输入 6 位 PIN 即可完成。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let pin = pairing.pin {
                HStack {
                    Text(pin)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .tracking(6)
                        .foregroundStyle(Theme.accentGradient)
                    Spacer()
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accent.opacity(0.08))
                )
            }

            Text(pairing.status)
                .font(.caption)
                .foregroundColor(pairing.lastError == nil ? .secondary : .red)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    if isPairing {
                        pairing.cancel()
                        isPairing = false
                    } else {
                        startPairing()
                    }
                } label: {
                    Label(isPairing ? "取消配对" : "开始本机配对",
                          systemImage: isPairing ? "xmark.circle" : "link.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(isPairing ? .red : Theme.accent)
            }
        }
        .card()
    }

    // MARK: - 导入配对

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入配对文件")
                .font(.subheadline.weight(.semibold))

            Text("支持 .mobiledevicepairing / .mobilepair / 从电脑导出的 plist。也可以直接把文件放进「文件 › 我的 iPhone › PosterDrop」。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    showImporter = true
                } label: {
                    Label("选择文件", systemImage: "doc.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    refresh()
                    if let first = candidates.first {
                        model.importPairing(from: first.url)
                        refresh()
                    } else {
                        model.banner = .info("文档目录里没有找到配对文件。")
                    }
                } label: {
                    Label("扫描文档", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .frame(height: 42)
                }
                .buttonStyle(.bordered)
            }
        }
        .card()
    }

    private var candidatesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在文档目录发现 \(candidates.count) 个候选文件")
                .font(.subheadline.weight(.semibold))

            ForEach(candidates) { candidate in
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.url.lastPathComponent)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text("\(candidate.source) · \(candidate.size) 字节")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("使用") {
                        model.importPairing(from: candidate.url)
                        refresh()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                }
            }
        }
        .card()
    }

    // MARK: - 说明

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配对方式对照")
                .font(.subheadline.weight(.semibold))

            guideRow(title: "SideStore", detail: "设置 › 配对 › 导入「文件 › 我的 iPhone › SideStore › ALTPairingFile.mobiledevicepairing」")
            guideRow(title: "LiveContainer", detail: "在 LiveContainer 的 SideStore 容器 Documents 里找到同名文件再导入")
            guideRow(title: "电脑导出", detail: "jitterbugpair / pymobiledevice3 生成配对文件后 AirDrop 到手机")
            guideRow(title: "本机配对", detail: "iOS 27+：点上面的「开始本机配对」，到设置里输入 PIN")

            Divider().opacity(0.4)

            Text("配对记录等同于设备调试凭据，仅保存在本机沙盒内，请勿分享给他人。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func guideRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 动作

    private func refresh() {
        model.refreshPairingState()
        tunnelReport = TunnelStatus.probe()
        candidates = PairingStore.shared.discoveredPairingFiles()
    }

    private func startPairing() {
        isPairing = true
        Task {
            do {
                _ = try await pairing.startAndWait()
                model.refreshPairingState()
                model.banner = .success("本机配对成功，配对记录已保存。")
            } catch {
                model.banner = .error(error.localizedDescription)
            }
            isPairing = false
        }
    }
}
