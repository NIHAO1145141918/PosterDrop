//
//  CleanerView.swift
//  PosterDrop
//
//  缓存清理页：先统计、再勾选、最后一次性删。
//
//  设计上刻意只做「可重建的数据」：壁纸本体放在 Application Support，
//  这里碰不到；页面上也把这条写给用户看，省得点之前心里没底。
//

import SwiftUI

struct CleanerView: View {

    @EnvironmentObject private var model: AppModel

    @State private var expanded = false
    @State private var showAllOthers = false

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

                        summaryCard

                        if model.cacheNeedsRespring {
                            respringHintCard
                        }

                        if model.isScanningCache || model.isCleaningCache {
                            WorkProgressCard(
                                title: model.isCleaningCache ? "正在清理…" : model.cacheScanNote,
                                progress: model.cacheProgress
                            )
                        }

                        if model.cacheTargets.isEmpty && !model.isScanningCache {
                            placeholderCard
                        } else {
                            appSection
                            posterBoardSection

                            if model.hasScannedOthers {
                                otherSection
                            } else {
                                deepScanCard
                            }

                            systemSection
                        }

                        safetyCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                    .readableColumn(820)
                }
            }
            .navigationTitle("清理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await model.scanCache(includeOthers: model.hasScannedOthers) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isScanningCache || model.isCleaningCache || model.isWorking)
                }
            }
            .safeAreaInset(edge: .bottom) {
                cleanBar
            }
            .task {
                if model.cacheTargets.isEmpty {
                    await model.scanCache()
                }
            }
        }
    }

    // MARK: - 总览

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("可清理")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    Text(CacheFormat.size(model.cacheTotalBytes))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.cacheTotalBytes)

                    Text(summarySubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await model.scanCache(includeOthers: model.hasScannedOthers) }
                } label: {
                    if model.isScanningCache {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Theme.accent.opacity(0.12)))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
                .disabled(model.isScanningCache || model.isCleaningCache || model.isWorking)
            }

            if let report = model.cacheLastReport, report.bytes > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundColor(Color(red: 0.18, green: 0.66, blue: 0.42))
                    Text("上次释放 \(CacheFormat.size(report.bytes)) · \(String(format: "%.1f", report.elapsed)) 秒")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .card()
    }

    /// 清掉 PosterBoard 缓存后，缩略图要等系统重建；给个一键重启的入口，别让用户以为壁纸没了。
    private var respringHintCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("重建壁纸缩略图")
                    .font(.footnote.weight(.medium))
                Text("PosterBoard 缓存已清空，重启桌面后系统会重新生成预览图。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button {
                model.respringManually()
                model.cacheNeedsRespring = false
            } label: {
                Text("重启")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.small)
        }
        .card(padding: 14)
    }

    private var summarySubtitle: String {
        if model.isScanningCache { return model.cacheScanNote }
        guard let date = model.cacheScanDate else { return "还没有统计过缓存大小。" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let count = model.cacheTargets.filter { $0.isCleanable }.count
        return "\(count) 项可清理 · \(formatter.string(from: date)) 统计"
    }

    // MARK: - 分组

    private var appSection: some View {
        groupCard(
            title: "本 App",
            icon: "app.badge",
            targets: model.cacheTargets.filter { $0.scope == .app }
        )
    }

    @ViewBuilder
    private var posterBoardSection: some View {
        let targets = model.cacheTargets.filter { $0.scope == .posterBoard }

        if targets.isEmpty {
            hintCard(
                icon: "photo.stack",
                title: "PosterBoard 壁纸",
                text: "还没定位到 PosterBoard 容器。去「诊断」页点一次「自动探测」，回来刷新就能统计壁纸缓存。"
            )
        } else {
            groupCard(title: "PosterBoard 壁纸", icon: "photo.stack", targets: targets)
        }
    }

    @ViewBuilder
    private var otherSection: some View {
        let targets = model.cacheTargets.filter { $0.scope == .other }

        if targets.isEmpty {
            hintCard(
                icon: "square.grid.2x2",
                title: "其他 App",
                text: "这次没有扫到其他 App 的缓存。可以下拉刷新再试，或先在「诊断」页让容器扫描跑一次。"
            )
        } else {
            groupCard(title: "其他 App", icon: "square.grid.2x2", targets: targets, collapsed: true)
        }
    }

    @ViewBuilder
    private var systemSection: some View {
        let targets = model.cacheTargets.filter { $0.scope == .system }

        if !targets.isEmpty {
            groupCard(title: "系统（跨 App）", icon: "internaldrive", targets: targets)
        }
    }

    private func hintCard(icon: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var deepScanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("其他 App")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            Text("逐个 App 统计缓存、临时文件、快照、Cookie 与网页数据，按占用从大到小排。容器父目录一次授权后直接进入每个 App，通常几秒内完成；没有缓存索引时会先花一次时间反查容器。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await model.scanCache(includeOthers: true) }
            } label: {
                Label("深度扫描所有 App", systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .disabled(model.isScanningCache || model.isCleaningCache || model.isWorking)
        }
        .card()
    }

    private func groupCard(
        title: String,
        icon: String,
        targets: [CacheTarget],
        collapsed: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent)

                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                let cleanable = targets.filter { $0.isCleanable }
                if !cleanable.isEmpty {
                    Button {
                        model.toggleAllCache(in: targets.first?.scope ?? .app)
                    } label: {
                        Text(allSelected(in: targets) ? "取消全选" : "全选")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.accent)
                }
            }
            .padding(.bottom, 6)

            if targets.isEmpty {
                Text("没有可统计的项目")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                let limit = 6
                let visible = (collapsed && !showAllOthers) ? Array(targets.prefix(limit)) : targets

                ForEach(visible) { target in
                    if target.id != visible.first?.id {
                        Divider().opacity(0.35)
                    }
                    row(target)
                }

                if collapsed && targets.count > limit {
                    Divider().opacity(0.35)
                    Button {
                        withAnimation(.snappy) { showAllOthers.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showAllOthers ? "收起" : "展开其余 \(targets.count - limit) 个 App")
                                .font(.caption2.weight(.semibold))
                            Image(systemName: showAllOthers ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundColor(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .card()
    }

    private func allSelected(in targets: [CacheTarget]) -> Bool {
        let cleanable = targets.filter { $0.isCleanable }
        return !cleanable.isEmpty && cleanable.allSatisfy { $0.isSelected }
    }

    // MARK: - 行

    private func row(_ target: CacheTarget) -> some View {
        Button {
            model.toggleCacheTarget(target.id)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol(for: target))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(tint(for: target).opacity(target.isCleanable ? 1 : 0.4))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tint(for: target).opacity(target.isCleanable ? 0.12 : 0.05))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(target.isCleanable ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let subtitle = target.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text(target.detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let caution = target.caution {
                        Text(caution)
                            .font(.caption2)
                            .foregroundColor(.orange.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(target.sizeText)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundColor(target.isCleanable ? .primary : .secondary)

                    Text(stateText(target))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Image(systemName: target.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(target.isSelected ? Theme.accent : Color.secondary.opacity(0.35))
                    .opacity(target.isCleanable ? 1 : 0.3)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!target.isCleanable)
    }

    private func stateText(_ target: CacheTarget) -> String {
        switch target.state {
        case .ready: return CacheFormat.count(target.files)
        case .empty: return "已清空"
        case .missing: return "不存在"
        case .denied: return "无权限"
        case .pending: return "统计中"
        }
    }

    private func symbol(for target: CacheTarget) -> String {
        switch target.id {
        case "app.staging": return "shippingbox"
        case "app.caches": return "square.stack.3d.up"
        case "pb.Library/Caches": return "photo.stack"
        case "pb.tmp": return "clock.arrow.circlepath"
        case "pb.Library/SplashBoard": return "rectangle.on.rectangle"
        case "pb.Library/Saved Application State": return "macwindow"
        case "pb.Library/HTTPStorages": return "network"
        case "pb.Library/Cookies": return "person.badge.key"
        case "pb.Library/WebKit": return "globe"
        case "pb.Library/Logs": return "doc.text.magnifyingglass"
        default:
            if target.id.hasPrefix("sys.") {
                if target.id.contains("CrashReporter") { return "exclamationmark.triangle" }
                if target.id.contains("SplashBoard") { return "rectangle.stack.badge.minus" }
                return "internaldrive"
            }
            return "app.dashed"
        }
    }

    private func tint(for target: CacheTarget) -> Color {
        switch target.scope {
        case .app: return Theme.accent
        case .posterBoard: return Color(red: 0.85, green: 0.36, blue: 0.62)
        case .other: return Color(red: 0.95, green: 0.55, blue: 0.25)
        case .system: return Color(red: 0.55, green: 0.42, blue: 0.92)
        }
    }

    // MARK: - 空态

    private var placeholderCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 74, height: 74)
                Image(systemName: "trash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }

            Text("还没有统计")
                .font(.headline)

            Text(model.isWorking
                 ? "正在注入壁纸，等这次任务完成后再统计缓存。"
                 : "点右上角的刷新按钮统计一次。\n只会统计可重建的缓存，壁纸本体不会被算进来。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await model.scanCache() }
            } label: {
                Label("开始统计", systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(model.isWorking || model.isScanningCache || model.isCleaningCache)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .card()
    }

    // MARK: - 安全说明

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundColor(Theme.accent)
                Text("清理边界")
                    .font(.subheadline.weight(.semibold))
            }

            safetyLine("只动白名单里的 8 个位置：缓存、tmp、快照、窗口状态、网络缓存、Cookie、网页数据、日志；壁纸本体在 Application Support，不会被删。")
            safetyLine("遇到符号链接只删链接本身，不会顺着链接清到别的容器。")
            safetyLine("清理过程中会给每一层目录单独签发写权限，失败的项目会列在日志里，不会“删一半就停”。")
            safetyLine("Cookie、网络缓存、网页数据被标为「需重新登录」，默认不勾；系统那组要清桌面快照和共享缓存，同样默认不勾。")

            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "收起细节" : "为什么这样更安全")
                        .font(.caption.weight(.semibold))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundColor(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            if expanded {
                Text("清理走的是与注入同一条 worse_query 通道：先把 App Group 的 Library/Caches 换成指向目标目录的符号链接，让 containermanagerd 签发沙箱扩展，再逐层删除。所有目标路径都由「合法容器根 + 固定相对路径」拼出来，界面上没有任何方式传入任意路径，所以不可能清到 Documents 或 Preferences。系统那三项目标是硬编码的绝对路径，删除前还会做一次精确白名单校验，多一层都不会碰。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private func safetyLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.accent.opacity(0.5))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 底部按钮

    private var cleanBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)

            Button {
                Task { await model.cleanCache() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text(cleanTitle)
                    if model.isCleaningCache {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!model.canCleanCache)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .readableColumn()
        }
        .background(.ultraThinMaterial)
    }

    private var cleanTitle: String {
        let count = model.selectedCacheTargets.count
        guard count > 0 else { return "选择要清理的项目" }
        return "清理 \(count) 项 · \(CacheFormat.size(model.selectedCacheBytes))"
    }
}
