//
//  PairingSheet.swift
//  PosterDrop
//
//  配对文件导入 + RSD 探测。
//
//  设计取向：不要求用户开开发者模式、不跑 RPPairing、不输 PIN。
//  配对记录从「已经和这台设备配对过的电脑」导出后直接丢进来即可。
//  导入只解决「我是谁」，「设备认不认我」取决于这份记录是不是在这台
//  设备上配对成功过的——所以界面上把这句话写在最显眼的位置。
//

import SwiftUI

struct PairingSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var hasPairing = PairingStore.shared.hasPairing
    @State private var summary = PairingStore.shared.summary
    @State private var showingPicker = false
    @State private var busy = false
    @State private var report: RemoteProbeReport?
    @State private var message: String?
    @State private var logs: [String] = []
    @State private var localFiles: [PairingCandidate] = []

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        introCard
                        statusCard
                        actionCard
                        if let report {
                            resultCard(report)
                        }
                        if !logs.isEmpty {
                            logCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                    .readableColumn(720)
                }
            }
            .navigationTitle("配对通道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPicker) {
                DocumentPicker(
                    allowsMultipleSelection: false,
                    allowsFolders: false,
                    copiesFiles: true
                ) { urls in
                    showingPicker = false
                    guard let url = urls.first else { return }
                    importPairing(url)
                } onCancel: {
                    showingPicker = false
                }
                .ignoresSafeArea()
            }
            .onChange(of: showingPicker) { _, showing in
                // 选择器里可能刚把文件拷进/移出文件夹，关掉时重扫一遍。
                if !showing { refreshState() }
            }
            .onAppear { refreshState() }
        }
    }

    // MARK: - 说明

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("这是什么", systemImage: "key.horizontal")
                .font(.subheadline.weight(.semibold))

            Text("配对文件是设备给「可信主机」的凭证。有它，App 才能通过 RSD 调用 installation_proxy，一次拿到所有 App 的容器路径——1 秒，而不是扫 1.2 亿个 inode 的 250 秒。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("文件从哪来").font(.caption.weight(.semibold))
                bullet("Mac 上配过对的设备：`~/Library/Lockdown/<UDID>.plist`")
                bullet("SideStore / LiveContainer 导出的 `.mobiledevicepairing`")
                bullet("其他能从电脑导出配对记录的签名工具")
            }

            Text("必须是**这台设备**上配对成功过的那份记录。别人的记录里没有你的公钥，握手会被直接拒绝。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").font(.caption)
            Text(.init(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: hasPairing ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(hasPairing ? Color.green : Color.secondary)
                Text(hasPairing ? "配对文件已导入" : "还没有配对文件")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if hasPairing {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(PairingStore.shared.sourceName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    // MARK: - 操作

    private var actionCard: some View {
        VStack(spacing: 10) {
            // App 自己的文件夹里已经有配对文件时直接列出来：点一下就走完，
            // 不用等系统选择器把 iCloud 目录列出来。
            if !localFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("App 文件夹里的配对文件")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(localFiles) { file in
                        Button {
                            importPairing(file.url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.badge.key")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.url.lastPathComponent)
                                        .font(.footnote)
                                        .lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(.tint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            Button {
                showingPicker = true
            } label: {
                Label(localFiles.isEmpty ? "导入配对文件" : "从其他位置导入", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

            // 选择器把 `.plist` 置灰时（iOS 对未声明的类型会这么做），
            // 这条是唯一不折腾的路：把文件挪进 App 自己的文件夹，页面直接列出来。
            if localFiles.isEmpty {
                Text("如果系统选择器里 `.plist` 点不动：在「文件」App 里长按它 → 移动 →「我的 iPhone / iPad」→ PosterDrop，再回到本页，文件会出现在上方。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                runProbe()
            } label: {
                HStack {
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                    Text(busy ? "正在探测…" : "测试 RSD 通道")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(busy || !hasPairing)

            if hasPairing {
                Button(role: .destructive) {
                    PairingStore.shared.delete()
                    RemoteContainerIndex.shared.clear()
                    refreshState()
                    report = nil
                    logs = []
                    message = "已清除配对文件"
                } label: {
                    Text("移除配对文件").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            }
        }
        .card()
    }

    // MARK: - 结果

    private func resultCard(_ report: RemoteProbeReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: report.isUsable ? "bolt.horizontal.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(report.isUsable ? Color.green : Color.orange)
                Text(report.state.rawValue)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.2fs", report.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if report.isUsable {
                HStack(spacing: 18) {
                    metric("App", "\(report.appCount)")
                    metric("容器", "\(report.containerCount)")
                    metric("通道", report.host)
                }
            }

            Text(report.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if report.isUsable {
                Text("已经可以跳过全卷扫描。回到「清理」页点一次统计，会直接复用这份索引。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("探测过程")
                .font(.caption.weight(.semibold))
            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    // MARK: - 动作

    private func importPairing(_ url: URL) {
        message = nil
        do {
            let size = try PairingStore.shared.adopt(url: url)
            message = "已导入 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
            RemoteContainerIndex.shared.clear()
            refreshState()
        } catch {
            message = error.localizedDescription
        }
    }

    private func refreshState() {
        hasPairing = PairingStore.shared.hasPairing
        summary = PairingStore.shared.summary
        localFiles = PairingStore.shared.discoveredPairingFiles()
    }

    private func runProbe() {
        busy = true
        message = nil
        logs = []
        let started = Date()

        Task {
            let collected = LogSink()
            let result = await Task.detached(priority: .userInitiated) {
                RemoteContainerIndex.shared.probe(log: { line in
                    collected.append(line)
                })
            }.value

            var lines = collected.lines
            // 把关键结论也放进列表，便于截图反馈
            lines.append(result.logLine)
            if result.isUsable {
                lines.append("耗时 \(String(format: "%.2f", Date().timeIntervalSince(started))) 秒")
            }

            await MainActor.run {
                logs = lines
                report = result
                busy = false
            }
        }
    }
}

/// 探测在后台线程跑，日志需要线程安全地攒起来。
private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
